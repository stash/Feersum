#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use Socket qw(SOL_SOCKET SO_RCVBUF AF_INET SOCK_STREAM);
use IO::Socket::INET ();
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 4;

use AnyEvent;
use EV;

# A TLS write issued from an independent event source (a timer, a deferred
# responder) enters try_tls_conn_write() with in_callback == 0, so its blocked
# exits must arm the write watcher themselves or the response is truncated.
my $BODY_LEN = 8 * 1024 * 1024;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
$evh->set_tls(cert_file => $cert_file, key_file => $key_file);
$evh->write_timeout(0);   # isolate watcher arming from timeout reaping
$evh->read_timeout(30 * TIMEOUT_MULT);

our %KEEP;
$evh->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'application/octet-stream']]);
        $KEEP{"$w"} = $w;
        # Small first chunk: flushes completely inside the handler, after which
        # the streaming path stops the write watcher.
        $w->write('x' x 16);
        # Large chunk from an independent timer, i.e. with in_callback == 0.
        my $t; $t = AE::timer 0.2, 0, sub {
            undef $t;
            $w->write('y' x $BODY_LEN);
            $w->close;
        };
    };
});

pipe(my $rpt_r, my $rpt_w) or die "pipe: $!";

my $pid = fork();
die "fork: $!" unless defined $pid;

if (!$pid) {
    # Client: read the headers, stall long enough for the server to block on
    # writability, then resume draining and report what actually arrived.
    close $rpt_r;
    my $report = sub { syswrite($rpt_w, "$_[0]\n"); exit 0 };
    select undef, undef, undef, 0.3;
    # A real IO::Socket, not a bare glob: start_SSL on a glob croaked
    # "bad open mode" under IO::Socket::SSL 2.096 on CPAN Testers.
    my $s = IO::Socket::INET->new(Proto => q{tcp}) or $report->("ERR socket $!");
    # SO_RCVBUF must be set before connect() or it does not take effect.
    setsockopt($s, SOL_SOCKET, SO_RCVBUF, pack('I', 4096));
    $s->connect(Socket::pack_sockaddr_in($port, Socket::inet_aton('127.0.0.1')))
        or $report->("ERR connect $!");
    IO::Socket::SSL->start_SSL($s,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE())
        or $report->("ERR handshake " . IO::Socket::SSL::errstr());
    syswrite($s, "GET /big HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        or $report->("ERR request $!");

    my $head = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10 * TIMEOUT_MULT;
        while ($head !~ /\r\n\r\n/) {
            my $n = sysread($s, my $b, 512);
            last unless $n;
            $head .= $b;
        }
        alarm 0; 1;
    } or $report->("ERR headers $@");
    $head =~ m{^HTTP/1\.[01] 200} or $report->("ERR status $head");

    select undef, undef, undef, 1.5;   # stall: server blocks on writability

    my $got = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 30 * TIMEOUT_MULT;
        while (1) {
            my $n = sysread($s, my $b, 65536);
            last if !defined($n) || $n == 0;
            $got += $n;
        }
        alarm 0; 1;
    } or $report->("STALLED $got");
    $report->("OK $got");
}

close $rpt_w;

my $cv = AE::cv;
my $line = '';
my $io_w = AE::io($rpt_r, 0, sub {
    my $n = sysread($rpt_r, my $b, 1024);
    if (!defined($n) || $n == 0) { $cv->send } else { $line .= $b; $cv->send if $line =~ /\n/ }
});
my $bail = AE::timer 90 * TIMEOUT_MULT, 0, sub { $line ||= "ERR parent timed out"; $cv->send };
$cv->recv;
chomp $line;

my ($verdict, $detail) = split ' ', $line, 2;
$detail = '' unless defined $detail;

is $verdict, 'OK', "client drained the response without stalling"
    or diag "client reported: $line";

# The body is chunked, so framing bytes ride along; require the whole payload.
# Pre-fix this was ~1.7 MB of 8 MB: the write watcher was never armed, so the
# remainder was never flushed even with the client actively reading.
cmp_ok $detail, '>=', $BODY_LEN,
    "received the entire $BODY_LEN-byte body (got $detail)";

# AnyEvent's child handling may have reaped the client already, leaving
# waitpid to return -1 with $? meaningless.  The verdict asserted above is the
# real evidence that it finished; only check the status when we did the reaping.
my $reaped = waitpid $pid, 0;
if ($reaped == $pid) {
    is $?, 0, 'client exited cleanly';
}
else {
    pass 'client exited cleanly (already reaped elsewhere)';
}
