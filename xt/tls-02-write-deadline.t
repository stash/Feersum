#!perl
# On TLS, write_timeout is a stall deadline, not a total-transfer budget: a
# client that keeps draining is never reaped no matter how long the body takes.
# Only visible with write_timeout > 0 and a body too big to flush tls_wbuf in
# one pass; no other test combines the two.
# Author-only: asserts a stall deadline over seconds of steady draining.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use Socket qw(AF_INET SOCK_STREAM SOL_SOCKET SO_RCVBUF);
use IO::Socket::INET ();
use Time::HiRes qw(time sleep);
use lib 't'; use Utils;
use Feersum;

my $evh = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 4;

use AnyEvent;
use EV;

my $BODY_LEN    = 8 * 1024 * 1024;
my $WRITE_TIMEO = 2 * TIMEOUT_MULT;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

$evh->use_socket($socket);
$evh->set_tls(cert_file => $cert, key_file => $key);
$evh->write_timeout($WRITE_TIMEO);
$evh->read_timeout(120 * TIMEOUT_MULT);

our %KEEP;
$evh->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'application/octet-stream']]);
        $KEEP{"$w"} = $w;
        $w->write('y' x $BODY_LEN);
        $w->close;
    };
});

pipe(my $rpt_r, my $rpt_w) or die "pipe: $!";

my $pid = fork();
die "fork: $!" unless defined $pid;

if (!$pid) {
    close $rpt_r;
    my $report = sub { syswrite($rpt_w, "$_[0]\n"); exit 0 };
    select undef, undef, undef, 0.3;
    # A real IO::Socket, not a bare glob: start_SSL on a glob croaked
    # "bad open mode" under IO::Socket::SSL 2.096 on CPAN Testers.
    my $s = IO::Socket::INET->new(Proto => q{tcp}) or $report->("ERR socket");
    # A small receive buffer forces many partial flushes server-side.
    setsockopt($s, SOL_SOCKET, SO_RCVBUF, pack('I', 16384));
    $s->connect(Socket::pack_sockaddr_in($port, Socket::inet_aton('127.0.0.1')))
        or $report->("ERR connect");
    IO::Socket::SSL->start_SSL($s, SSL_verify_mode => 0)
        or $report->("ERR handshake");
    syswrite($s, "GET /big HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        or $report->("ERR write");

    my $head = '';
    while ($head !~ /\r\n\r\n/) {
        my $n = sysread($s, my $b, 256);
        last unless $n;
        $head .= $b;
    }
    $head =~ m{\AHTTP/1\.[01] 200} or $report->("ERR status");

    # Drain STEADILY and slowly - never stalled, always making progress, but
    # far slower than write_timeout.  This must NOT be reaped.
    my $got = 0;
    my $t0  = time;
    while (1) {
        my $n = sysread($s, my $b, 32768);
        last if !defined($n) || $n == 0;
        $got += $n;
        # Pace only until the transfer has clearly outlived write_timeout -
        # that is the whole point of the test - then drain at full speed.
        # Pacing the entire 8 MB made the run take minutes on a slow or
        # instrumented host (under valgrind it exceeded the bail-out below and
        # the test false-failed on a short body).
        if (time - $t0 < $WRITE_TIMEO * 3) {
            sleep 0.021 * TIMEOUT_MULT;   # ~1.5 MB/s, scaled with the deadline
        }
        last if time - $t0 > 120 * TIMEOUT_MULT;
    }
    $report->(sprintf "OK %d %.2f", $got, time - $t0);
}

close $rpt_w;

my $cv = AE::cv;
my $line = '';
my $io_w = AE::io($rpt_r, 0, sub {
    my $n = sysread($rpt_r, my $b, 1024);
    if (!defined($n) || $n == 0) { $cv->send }
    else { $line .= $b; $cv->send if $line =~ /\n/ }
});
my $bail = AE::timer 120 * TIMEOUT_MULT, 0, sub { $line ||= "ERR parent-timeout"; $cv->send };
$cv->recv;
chomp $line;

my ($verdict, $got, $elapsed) = split ' ', $line;
$_ //= 0 for $got, $elapsed;

is $verdict, 'OK', "client drained the TLS response" or diag "client said: $line";

# The transfer must take much longer than write_timeout - otherwise the
# deadline was never at risk and this test proves nothing.
cmp_ok $elapsed, '>', $WRITE_TIMEO * 2,
    "transfer outlasted write_timeout by a wide margin (${elapsed}s)";

# Chunked framing rides along, so require at least the payload.
cmp_ok $got, '>=', $BODY_LEN,
    "steadily-draining client got the whole $BODY_LEN-byte body (got $got)";

waitpid $pid, 0;
