#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use Time::HiRes ();
use IO::Socket::INET;
use lib 't'; use Utils;

use Feersum;
use AnyEvent;
use EV;

# read_timeout is also the keepalive idle clock, and a response counts as
# delivered once queued - so it used to reap a connection whose client was
# still draining megabytes.  Plain HTTP on purpose: t/33 covers the same
# property but only on Linux, over TLS, through sendfile.
my $RTO  = 1 * TIMEOUT_MULT;
my $BIG  = 'x' x 300_000;
my $SMALL = 'y' x 150_000;

my $evh = Feersum->new();
plan skip_all => 'no kernel send-queue probe (SIOCOUTQ/SO_NWRITE/FIONWRITE) on this platform'
    unless $evh->has_outq_probe;
# Same send-buffer premise as t/88d: kqueue's 1-byte write watermark and the
# peer's receive buffer swallowing the body break both halves of this test
# (macOS loses the keepalive, the BSDs never arm the idle clock at all).
plan skip_all => "Linux-specific send-buffer behaviour (this is $^O)"
    unless $^O eq 'linux';
plan tests => 5;
my ($socket, $port) = get_listen_socket();
ok $socket, "listening on $port";
$evh->use_socket($socket);
$evh->set_keepalive(1);
$evh->read_timeout($RTO);
$evh->request_handler(sub {
    my $r = shift;
    my $body = $r->env->{PATH_INFO} =~ m{small} ? \$SMALL : \$BIG;
    $r->send_response("200 OK",
        ['Content-Type' => 'text/plain', 'Content-Length' => length $$body], $$body);
});

sub client_sock {
    my $s = IO::Socket::INET->new(Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT)
        or die "socket: $!";
    setsockopt($s, Socket::SOL_SOCKET(), Socket::SO_RCVBUF(), pack('I', 16 * 1024));
    $s->connect(Socket::pack_sockaddr_in($port, Socket::inet_aton('127.0.0.1')))
        or die "connect: $!";
    return $s;
}

# 1. A client slower than read_timeout must still get its whole response AND
#    keep the connection for the next request.
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    my $s = client_sock();
    $s->print("GET /big HTTP/1.1\r\nHost: l\r\n\r\n");
    my $want = length($BIG);
    my $rate = $want / (4 * $RTO);          # four read_timeout intervals
    my ($resp, $t0) = (q{}, Time::HiRes::time());
    my ($max_gap, $last) = (0, $t0);
    while (1) {
        my $n = sysread($s, my $b, 8192);
        last if !$n;
        my $now = Time::HiRes::time();
        $max_gap = $now - $last if $now - $last > $max_gap;
        $last = $now;
        $resp .= $b;
        last if $resp =~ /\r\n\r\n/
             && length($resp) >= index($resp, "\r\n\r\n") + 4 + $want;
        my $sleep = length($resp) / $rate - (Time::HiRes::time() - $t0);
        select undef, undef, undef, $sleep if $sleep > 0;
    }
    my (undef, $body) = split /\r\n\r\n/, $resp, 2;
    exit 2 unless length($body // '') == $want;

    $s->print("GET /big HTTP/1.1\r\nHost: l\r\nConnection: close\r\n\r\n");
    my $hdr = q{};
    while (length($hdr) < 15) {
        my $n = sysread($s, my $b, 15 - length $hdr);
        last if !$n;
        $hdr .= $b;
    }
    # A client the box descheduled for a whole interval is indistinguishable
    # from one that stopped reading, and the server is right to reap it.
    if ($hdr !~ m{^HTTP/1\.1 200} && $max_gap > $RTO) {
        warn sprintf "slow reader was descheduled %.1fs (read_timeout %ss)\n",
            $max_gap, $RTO;
        exit 9;
    }
    exit 3 unless $hdr =~ m{^HTTP/1\.1 200};
    exit 0;
}

my ($cv, $status) = (AE::cv, undef);
my $tmo = AE::timer(30 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') });
my $cw = AE::child($pid, sub { $status = $_[1] >> 8; $cv->send('done') });
isnt $cv->recv, 'timeout', 'slow reader did not timeout';
isnt $status, 2, 'slow reader received the whole response';
SKIP: {
    skip 'client was descheduled for a whole read_timeout (overloaded box)', 1
        if (($status // 0) == 9);
    is $status, 0, 'keepalive survived a drain longer than read_timeout';
}

# 2. ...but a client that stops reading is still reaped.  Small enough that the
#    whole response reaches the kernel, which is what arms the idle clock.
my $pid2 = fork();
die "fork: $!" unless defined $pid2;
if ($pid2 == 0) {
    my $s = client_sock();
    $s->print("GET /small HTTP/1.1\r\nHost: l\r\n\r\n");
    select undef, undef, undef, 25 * TIMEOUT_MULT;   # never read a byte
    exit 0;
}

my ($cv2, $seen, $reaped) = (AE::cv, 0, 0);
my $tmo2 = AE::timer(20 * TIMEOUT_MULT, 0, sub { $cv2->send });
my $poll = AE::timer(0.25, 0.25, sub {
    my $n = $evh->active_conns;
    $seen = 1 if $n;
    if ($seen && !$n) { $reaped = 1; $cv2->send }
});
$cv2->recv;
kill 'QUIT', $pid2;
waitpid($pid2, 0);
ok $reaped, 'a client that stops reading is still reaped';
