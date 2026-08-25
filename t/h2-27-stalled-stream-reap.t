#!perl
# An H2 stream holding a response behind a zero window while the peer stays
# silent is reaped after FEER_H2_STALL_STRIKES read_timeout intervals; a stream
# with nothing pending (idle SSE) stays exempt, and t/159 covers slow readers.
use warnings; use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
use H2Utils;
use IO::Socket::INET;
use Time::HiRes ();
use POSIX ();
use Feersum;
use Errno qw(EAGAIN EWOULDBLOCK ECONNRESET);

# A reaped connection is closed right after its GOAWAY.  Detecting the close
# is portable where parsing the last frame is not: OpenBSD surfaces the
# teardown as a reset (undef/ECONNRESET) or a half-read record, not the clean
# EOF Linux gives.  Drain whatever arrived; treat EOF or a hard error as dead,
# a would-block (including a partial TLS record) as still alive.
sub sock_dead {
    my $s = shift;
    my $rin = ''; vec($rin, fileno($s), 1) = 1;
    return 0 unless select($rin, undef, undef, 0.2);
    my $buf = ''; my $n = sysread($s, $buf, 65536);
    return 1 if defined $n && $n == 0;                 # clean EOF / close_notify
    return 0 if defined $n;                             # got data: still draining
    return 0 if $! == EAGAIN || $! == EWOULDBLOCK;      # partial record, alive
    return 1;                                            # reset or other hard error
}

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan tests => 3;

my $RTO     = 2 * TIMEOUT_MULT;   # read_timeout; reap lands at ~3x this
my $NSTREAM = 8;
my $BODY    = 512 * 1024;         # big enough to stall behind a zero window

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout($RTO);
    $f->header_timeout(60 * TIMEOUT_MULT);
    # write_timeout deliberately left at its default (off): the reap must not
    # depend on the operator opting into it.
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 1) };
    $f->psgi_request_handler(sub {
        [200, ['Content-Type' => 'application/octet-stream',
               'Content-Length' => $BODY], ['Z' x $BODY]] });
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

my $raw = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                Timeout => 10 * TIMEOUT_MULT) or die "connect: $!";
my $s = IO::Socket::SSL->start_SSL($raw,
    SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
    SSL_alpn_protocols => ['h2']) or die "start_SSL: $!";
# INITIAL_WINDOW_SIZE = 0: the server may not send a single DATA byte, so every
# response stalls with its whole body pinned in resp_body.
$s->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
           . h2_frame(H2_SETTINGS, 0, 0, pack('nN', 0x4, 0)));
$s->blocking(0);
for my $i (1 .. $NSTREAM) {
    my $sid = 2*$i - 1;
    my $h = hpack_encode_headers([':method','GET'], [':scheme','https'],
              [':authority',"127.0.0.1:$port"], [':path',"/s$sid"]);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $sid, $h));
}
# From here the client is SILENT: no PING, no WINDOW_UPDATE, no SETTINGS ACK.
# Only a working reaper tears the connection down within the deadline.
my $deadline = Time::HiRes::time() + $RTO * 8;
my $reaped = 0;
while (Time::HiRes::time() < $deadline) {
    if (sock_dead($s)) { $reaped = 1; last }
}
close $s;
ok $reaped, 'a silent zero-window client is reaped at the default write_timeout';

# A fresh streamless connection is still reaped on the ordinary idle clock -
# the fix must not have broken the base case.
my $raw2 = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                 Timeout => 10 * TIMEOUT_MULT) or die "connect2: $!";
my $s2 = IO::Socket::SSL->start_SSL($raw2,
    SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
    SSL_alpn_protocols => ['h2']) or die "start_SSL2: $!";
$s2->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" . h2_frame(H2_SETTINGS, 0, 0, ''));
$s2->blocking(0);
my $d2 = Time::HiRes::time() + $RTO * 6;
my $idle_reaped = 0;
while (Time::HiRes::time() < $d2) {
    if (sock_dead($s2)) { $idle_reaped = 1; last }
}
close $s2;
ok $idle_reaped, 'a streamless idle H2 connection is still reaped on the idle clock';

kill 'QUIT', $server;
waitpid $server, 0;
