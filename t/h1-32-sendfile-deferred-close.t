#!perl
# sendfile() and close() from a deferred callback, with the next request
# pipelined: completing the file must not end the response before close(), or
# the pipelined request is dispatched with no request (a NULL deref under PSGI).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET ();
use IO::Select ();
use File::Temp qw(tempdir);
use POSIX ();
use lib 't'; use Utils;
use Feersum;
use EV;

BEGIN {
    plan skip_all => 'sendfile() is only supported on Linux' unless $^O eq 'linux';
}

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
my $can_tls = Feersum->new_instance->has_tls && -f $cert && -f $key
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

plan tests => 12;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/body";
my $SIZE = 30;
{ open my $fh, '>', $file or die $!; print {$fh} 'F' x $SIZE; close $fh }

sub start_server {
    my ($api, $tls) = @_;
    my ($sock, $port) = get_listen_socket();
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        $SIG{QUIT} = 'DEFAULT';
        my $f = Feersum->new_instance;
        $f->use_socket($sock);
        $f->set_tls(listener => 0, cert_file => $cert, key_file => $key) if $tls;
        $f->set_keepalive(1);
        my %keep;
        my $deferred = sub {
            my $w = shift;
            $keep{t} = EV::timer(0.05, 0, sub {
                open my $fh, '<', $file or die $!;
                $w->sendfile($fh);
                close $fh;
                $w->close;
                delete $keep{t};
            });
        };
        if ($api eq 'psgi') {
            $f->psgi_request_handler(sub {
                my $env = shift;
                return [200, ['Content-Type' => 'text/plain'], ["second:$env->{PATH_INFO}"]]
                    unless $env->{PATH_INFO} eq '/file';
                return sub {
                    $deferred->($_[0]->([200, ['Content-Length' => $SIZE]]));
                };
            });
        }
        else {
            $f->request_handler(sub {
                my $r = shift;
                my $path = $r->path;    # croaks when dispatched with no request
                if ($path eq '/file') {
                    $deferred->($r->start_streaming(200, ['Content-Length' => $SIZE]));
                    return;
                }
                $r->send_response(200, ['Content-Type' => 'text/plain'], "second:$path");
            });
        }
        my $life = EV::timer(30 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $sock;
    return ($pid, $port);
}

sub pipelined {
    my ($port, $tls) = @_;
    my $c = $tls
        ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
              SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
              Timeout => 5 * TIMEOUT_MULT)
        : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
              Timeout => 5 * TIMEOUT_MULT);
    return '' unless $c;
    # both keepalive: a Connection: close on the second closes instead of
    # re-dispatching, which hides the crash
    syswrite $c, "GET /file HTTP/1.1\r\nHost: x\r\n\r\n"
        . "GET /next HTTP/1.1\r\nHost: x\r\n\r\n";
    my ($buf, $sel) = (q{}, IO::Select->new($c));
    my $deadline = time + 10 * TIMEOUT_MULT;
    while (time < $deadline && complete_responses($buf) < 2) {
        next unless ($tls && $c->pending) || $sel->can_read(0.5);
        my $n = sysread $c, my $chunk, 65536;
        last unless $n;
        $buf .= $chunk;
    }
    close $c;
    return $buf;
}

sub complete_responses {
    my $b = shift;
    my $n = 0;
    while ($b =~ /\A(HTTP\/1\.1 \d{3}[^\r]*\r\n.*?\r\n\r\n)/s) {
        my $head = $1;
        my ($cl) = $head =~ /^Content-Length:\s*(\d+)/mi;
        last unless defined $cl && length($b) >= length($head) + $cl;
        substr($b, 0, length($head) + $cl, q{});
        $n++;
    }
    return $n;
}

my @cases = (['psgi', 0], ['native', 0], ['psgi', 1]);
for my $case (@cases) {
    my ($api, $tls) = @$case;
    my $label = "$api " . ($tls ? 'TLS' : 'plain');
    SKIP: {
        skip "$label: no TLS support, test certificate or client", 4 if $tls && !$can_tls;
        my ($pid, $port) = start_server($api, $tls);
        my $resp = pipelined($port, $tls);
        select undef, undef, undef, 0.2;
        # not kill 0: a crashed child stays a zombie until reaped
        my $exited = waitpid($pid, POSIX::WNOHANG()) == $pid;
        ok !$exited, "$label: server survived the pipelined request"
            or diag 'server died, wait status ' . $?;
        my ($head1, $rest) = split /\r\n\r\n/, $resp, 2;
        like $head1 // q{}, qr{^HTTP/1\.1 200 .*Content-Length: $SIZE}s,
            "$label: first response committed Content-Length $SIZE";
        $rest //= q{};
        like substr($rest, 0, $SIZE + 12), qr/^F{$SIZE}HTTP\/1\.1 200\z/,
            "$label: the pipelined response starts right after the file";
        like $rest, qr{\r\n\r\nsecond:/next\z},
            "$label: the pipelined request reached the handler intact";
        unless ($exited) { kill 'QUIT', $pid; waitpid $pid, 0 }
    }
}
