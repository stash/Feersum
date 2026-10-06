#!perl
# After a psgix.io takeover the app owns the stream and its deadline: poll_cb
# plus peer bytes must not re-arm the read watchdog or inject an HTTP error.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use IO::Select;
use POSIX ();
use EV;
use Feersum;

plan tests => 5;

my ($listen, $port) = get_listen_socket();
ok $listen, 'listen socket' or BAIL_OUT('no listen socket');

pipe(my $rd, my $wr) or die "pipe: $!";
my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    close $rd;
    $SIG{QUIT} = 'DEFAULT';
    my ($KEEP_FH, $KEEP_ENV, $KEEP_IN, $cb_fired);
    my $f = Feersum->new_instance();
    $f->read_timeout(1 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        return sub {
            $KEEP_ENV = $env;
            $KEEP_FH = $env->{'psgix.io'};
            $KEEP_IN = $env->{'psgi.input'};
            $KEEP_IN->poll_cb(sub {
                my $junk = '';
                1 while $_[0]->read($junk, 65536);
                syswrite $wr, "CB\n" unless $cb_fired++;
            });
            syswrite $KEEP_FH, "HTTP/1.1 101 Switching Protocols\r\n"
                             . "Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n";
        };
    });
    $f->use_socket($listen);
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { POSIX::_exit(2) });
    EV::run();
    POSIX::_exit(3);
}
close $wr;
close $listen;

my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                              Timeout => 10 * TIMEOUT_MULT);
ok $s, 'connected' or BAIL_OUT('no connection');
$s->blocking(0);
syswrite $s, "GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
           . "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
           . "Sec-WebSocket-Version: 13\r\n\r\n";

my $sel = IO::Select->new($s, $rd);
my ($got, $cb, $eof) = ('', 0, 0);
my $sent = 0;
my $deadline = time + 4 * TIMEOUT_MULT + 2;
while (time < $deadline) {
    for my $fh ($sel->can_read(0.2)) {
        if ($fh == $rd) {
            sysread $rd, my $z, 4096;
            $cb = 1 if defined $z && $z =~ /CB/;
        } else {
            my $n = sysread $s, my $z, 4096;
            if (!$n) { $eof = 1; last }
            $got .= $z;
            if (!$sent && $got =~ /\r\n\r\n/) {
                syswrite $s, "HELLO";
                $sent = 1;
                $deadline = time + 2 * TIMEOUT_MULT + 1;
            }
        }
    }
    last if $eof;
}
close $s;

ok $cb, 'reader poll_cb fired on the peer byte (watchdog path exercised)';
unlike $got, qr/^HTTP\/1\.1 408/m,
    'no 408 injected into the app-owned stream after idle past read_timeout';
ok !$eof, 'takeover connection still open';

reap_server($server);
