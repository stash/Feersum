#!perl
# Test keepalive behavior when handler doesn't read POST body.
# Feersum drains unconsumed body bytes from rbuf so the connection
# can be reused without body/HTTP desync (RFC 9112 section 9.3).
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

plan tests => 10;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

my $call_count = 0;
my $read_body;

$feer->request_handler(sub {
    my $r = shift;
    $call_count++;
    my $env = $r->env();
    my $cl = $env->{CONTENT_LENGTH} || 0;
    my $body = '';
    if ($read_body && $cl > 0) {
        my $input = $env->{'psgi.input'};
        $input->read($body, $cl) if $input;
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'],
                      \"resp-$call_count");
});

# Test 1: POST body READ -> keepalive works
{
    $call_count = 0;
    $read_body = 1;
    run_client("body-read-keepalive", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # POST with body (handler reads it)
        $s->print("POST /a HTTP/1.1\015\012Host: l\015\012Content-Length: 5\015\012\015\012hello");
        my $r1 = '';
        while (my $l = <$s>) {
            $r1 .= $l;
            if ($r1 =~ /\015\012\015\012/ && $r1 =~ /Content-Length:\s*(\d+)/i) {
                $s->read(my $b, $1); $r1 .= $b; last;
            }
        }
        return 11 unless $r1 =~ /resp-1/;
        # GET on same connection
        $s->print("GET /b HTTP/1.1\015\012Host: l\015\012Connection: close\015\012\015\012");
        my $r2 = '';
        while (my $l = <$s>) { $r2 .= $l }
        return $r2 =~ /resp-2/ ? 0 : 12;
    });
    is $call_count, 2, 'body-read: handler called twice (keepalive works)';
}

# Test 2: POST body NOT read -> body drained by server, keepalive preserved
{
    $call_count = 0;
    $read_body = 0;
    run_client("body-skip-close", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # POST with body (handler skips it)
        $s->print("POST /a HTTP/1.1\015\012Host: l\015\012Content-Length: 5\015\012\015\012hello");
        my $r1 = '';
        while (my $l = <$s>) {
            $r1 .= $l;
            if ($r1 =~ /\015\012\015\012/ && $r1 =~ /Content-Length:\s*(\d+)/i) {
                $s->read(my $b, $1); $r1 .= $b; last;
            }
        }
        return 11 unless $r1 =~ /resp-1/;
        # GET on same connection - should work (body drained, keepalive preserved)
        $s->print("GET /b HTTP/1.1\015\012Host: l\015\012Connection: close\015\012\015\012");
        my $r2 = '';
        while (my $l = <$s>) { $r2 .= $l }
        return $r2 =~ /resp-2/ ? 0 : 12;
    });
    is $call_count, 2, 'body-skip: handler called twice (body drained, keepalive works)';
}

# Test 3: GET (no body) -> keepalive always works
{
    $call_count = 0;
    $read_body = 0;
    run_client("get-keepalive", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("GET /a HTTP/1.1\015\012Host: l\015\012\015\012");
        my $r1 = '';
        while (my $l = <$s>) {
            $r1 .= $l;
            if ($r1 =~ /\015\012\015\012/ && $r1 =~ /Content-Length:\s*(\d+)/i) {
                $s->read(my $b, $1); $r1 .= $b; last;
            }
        }
        return 11 unless $r1 =~ /resp-/;
        $s->print("GET /b HTTP/1.1\015\012Host: l\015\012Connection: close\015\012\015\012");
        my $r2 = '';
        while (my $l = <$s>) { $r2 .= $l }
        return $r2 =~ /resp-/ ? 0 : 12;
    });
    is $call_count, 2, 'get-keepalive: handler called twice';
}
