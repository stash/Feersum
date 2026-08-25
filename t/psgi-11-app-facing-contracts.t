#!perl
# Three app-facing contracts: psgi.input->close() on a fully buffered body
# keeps the connection and any pipelined request; a write poll_cb that dies is
# uninstalled rather than re-invoked forever; a 204 never carries Content-Length.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

plan tests => 14;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

my $died = 0;
{
    no warnings 'redefine';
    *Feersum::DIED = sub { $died++ };
}

my $call_count = 0;
# The streaming writer must outlive the handler, otherwise its DESTROY
# completes the response and closes the connection before poll_cb can fire.
my $keep_writer;

$feer->request_handler(sub {
    my $r = shift;
    $call_count++;
    my $env  = $r->env();
    my $path = $env->{PATH_INFO};

    if ($path eq '/polldie') {
        my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain']);
        $w->write("first");
        # Throws every time it is called.  Pre-fix this spun the event loop.
        $w->poll_cb(sub { die "boom\n" });
        $keep_writer = $w;   # keep it alive so poll_cb actually gets called
        return;
    }
    if ($path eq '/204') {
        # App supplies a Content-Length that must not reach the wire.
        $r->send_response(204, ['Content-Type' => 'text/plain',
                                'Content-Length' => 10], []);
        return;
    }

    # Default: read the whole body, then close psgi.input as the POD advises.
    my $cl = $env->{CONTENT_LENGTH} || 0;
    my $input = $env->{'psgi.input'};
    if ($input) {
        my $body = '';
        $input->read($body, $cl) if $cl > 0;
        $input->close();
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"resp-$call_count");
});

# Read one Content-Length-delimited response off $s.
sub read_one {
    my ($s) = @_;
    my $buf = '';
    while (my $l = <$s>) {
        $buf .= $l;
        last if $buf =~ /\015\012\015\012/;
    }
    if ($buf =~ /Content-Length:\s*(\d+)/i && $1) {
        $s->read(my $b, $1);
        $buf .= $b;
    }
    return $buf;
}

#####################################################################
# 1. psgi.input->close() must not break keepalive (sequential requests)
#####################################################################
{
    $call_count = 0;
    run_client("input-close-keepalive", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("POST /a HTTP/1.1\015\012Host: l\015\012".
                  "Content-Length: 5\015\012\015\012hello");
        return 11 unless read_one($s) =~ /resp-1/;
        # Second request on the SAME connection: pre-fix the server had already
        # shutdown(SHUT_RD), so this was never answered.
        $s->print("GET /b HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $r2 = '';
        while (my $l = <$s>) { $r2 .= $l }
        return 12 unless $r2 =~ /resp-2/;
        return 0;
    });
    is $call_count, 2, 'input->close(): keepalive survived, both requests served';
}

#####################################################################
# 2. psgi.input->close() must not discard an already-pipelined request
#####################################################################
{
    $call_count = 0;
    run_client("input-close-pipelined", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # Body and the next request arrive in one write; pre-fix close() freed
        # rbuf and the pipelined GET vanished.
        $s->print("POST /a HTTP/1.1\015\012Host: l\015\012".
                  "Content-Length: 5\015\012\015\012hello".
                  "GET /b HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        return 11 unless read_one($s) =~ /resp-1/;
        my $r2 = '';
        while (my $l = <$s>) { $r2 .= $l }
        return 12 unless $r2 =~ /resp-2/;
        return 0;
    });
    is $call_count, 2, 'input->close(): pipelined request still served';
}

#####################################################################
# 3. A dying write poll_cb must not spin; the connection must end
#####################################################################
{
    $call_count = 0;
    $died = 0;
    my $t0 = time;
    run_client("poll-cb-exception", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("GET /polldie HTTP/1.1\015\012Host: l\015\012\015\012");
        # Must reach EOF promptly.  Pre-fix the server looped forever and the
        # connection was never closed, so this read blocked until the timeout.
        my $buf = '';
        eval {
            local $SIG{ALRM} = sub { die "hang\n" };
            alarm 8 * TMULT;
            while (my $n = sysread($s, my $c, 4096)) { $buf .= $c }
            alarm 0;
            1;
        } or return 11;
        return 12 unless $buf =~ /first/;   # the pre-exception body arrived
        return 0;
    });
    cmp_ok time - $t0, '<', 8 * TMULT,
        'poll_cb exception: connection closed promptly (no infinite spin)';
    ok $died, 'poll_cb exception: reported through Feersum::DIED';
}

#####################################################################
# 4. 204 must not carry an app-supplied Content-Length
#####################################################################
{
    $call_count = 0;
    run_client("204-no-content-length", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("GET /204 HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $buf = '';
        while (my $l = <$s>) { $buf .= $l }
        return 11 unless $buf =~ m{^HTTP/1\.1 204 };
        return 12 if $buf =~ /Content-Length:/i;
        return 13 if $buf =~ /Transfer-Encoding:/i;
        return 0;
    });
    is $call_count, 1, '204: handler ran';
}
