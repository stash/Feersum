#!perl
# write_timeout must not truncate a peer still draining the kernel send buffer,
# even one too slow to re-trigger EPOLLOUT (Linux re-signals writability only
# after half the buffer frees); a peer that drains nothing for a full interval
# is still reaped.  Buffer sizes are pinned on both ends; assertions are bytes.
# Author-only: needs steady draining to tell a stalled peer from a slow one.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use Test::Fatal;
use lib 't'; use Utils;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_SNDBUF SO_RCVBUF SO_REUSEADDR SOMAXCONN
              AF_INET SOCK_STREAM inet_aton pack_sockaddr_in sockaddr_in);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Feersum;

my $evh = Feersum->new();
plan skip_all => 'no kernel send-queue probe (SIOCOUTQ/SO_NWRITE/FIONWRITE) on this platform'
    unless $evh->has_outq_probe;
# The defect this pins down is the Linux EPOLLOUT watermark (writability is
# reported only once ~half the send buffer drains).  kqueue reports a 1-byte
# low watermark, and pinning SO_SNDBUF there does not stop the peer's receive
# buffer swallowing the whole body, so neither the slow-reader nor the stuck
# premise holds.  t/time-03-write-timeout.t covers the reaper on those platforms.
plan skip_all => "Linux-specific send-buffer behaviour (this is $^O)"
    unless $^O eq 'linux';
plan tests => 10;

my $wt   = 1.0 * TIMEOUT_MULT;
my $BODY = 3 * 1024 * 1024;   # well above what the pinned kernel buffers absorb
my $CHUNK = 'x' x (1024 * 1024);

# Pin SO_SNDBUF before listen: accepted sockets inherit it.  512KB requested
# (1MB effective) means EPOLLOUT needs 512KB drained, which the slow reader
# below (~80KB/s) cannot manage within any sane write_timeout.
socket(my $lsock, AF_INET, SOCK_STREAM, 0) or die "socket: $!";
setsockopt($lsock, SOL_SOCKET, SO_REUSEADDR, pack('l', 1));
setsockopt($lsock, SOL_SOCKET, SO_SNDBUF, pack('l', 512 * 1024)) or die "sndbuf: $!";
bind($lsock, pack_sockaddr_in(0, inet_aton('127.0.0.1'))) or die "bind: $!";
listen($lsock, SOMAXCONN) or die "listen: $!";
my $fl = fcntl($lsock, F_GETFL, 0);
fcntl($lsock, F_SETFL, $fl | O_NONBLOCK) or die "nonblock: $!";
my ($port) = sockaddr_in(getsockname($lsock));
ok $port, "made pinned listen socket on port $port";

is exception { $evh->use_socket($lsock) }, undef, "bound to socket";
$evh->write_timeout($wt);

$evh->request_handler(sub {
    my $r = shift;
    if ($r->path eq '/streaming') {
        my $w = $r->start_streaming(200, ['Content-Type' => 'application/octet-stream']);
        $w->write($CHUNK) for 1 .. 3;
        $w->close;
    }
    else {
        $r->send_response(200,
            ['Content-Type' => 'application/octet-stream', 'Content-Length' => $BODY],
            [($CHUNK) x 3]);
    }
});

# Client socket with SO_RCVBUF pinned BEFORE connect (fixes the window scale
# and disables receive autotuning) so the kernel absorbs a known ~1.2MB total.
sub make_client {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(Proto => 'tcp') or die "socket: $!";
    $s->sockopt(SO_RCVBUF, 64 * 1024) or die "rcvbuf: $!";
    $s->connect(pack_sockaddr_in($port, inet_aton('127.0.0.1'))) or die "connect: $!";
    $s->syswrite("GET $path HTTP/1.0\r\nHost: localhost\r\n\r\n") or die "req: $!";
    $s->blocking(0);
    return $s;
}

# Read $path slowly (16KB every 0.2s, ~80KB/s: drains, but far below the
# 512KB EPOLLOUT threshold per interval) for slow_for seconds spanning
# several deadlines, then at full speed.  Returns (status, body_len, eof).
sub run_slow_reader {
    my ($path, $slow_for) = @_;
    my $s = make_client($path);
    my ($data, $eof) = ('', 0);
    my $cv = AE::cv;
    my ($tick, $io, $watchdog);
    my $finish = sub { undef $tick; undef $io; undef $watchdog; $eof = $_[0]; $cv->send };
    my $greedy = sub {
        $io = AE::io $s, 0, sub {
            while (1) {
                my $n = $s->sysread(my $buf, 65536);
                if (!defined $n) { return if $!{EAGAIN} || $!{EWOULDBLOCK}; return $finish->(0) }
                return $finish->(1) if $n == 0;
                $data .= $buf;
            }
        };
    };
    my $t0 = AE::now;
    $tick = AE::timer 0.2, 0.2, sub {
        my $n = $s->sysread(my $buf, 16384);
        if (defined $n) {
            return $finish->(1) if $n == 0;   # early EOF = server truncated us
            $data .= $buf;
        }
        elsif (!($!{EAGAIN} || $!{EWOULDBLOCK})) { return $finish->(0) }
        if (AE::now - $t0 >= $slow_for) { undef $tick; $greedy->() }
    };
    $watchdog = AE::timer 60 * TIMEOUT_MULT, 0, sub { $finish->(0) };
    $cv->recv;
    close $s;
    my ($hdr, $body) = split /\r\n\r\n/, $data, 2;
    my ($status) = defined $hdr ? $hdr =~ m{^HTTP/1\.\d (\d+)} : ();
    return ($status, defined $body ? length $body : 0, $eof);
}

# Phase 1: buffered response to a slow-but-draining reader survives several
# deadlines and arrives complete.  Slow phase spans >= 4 deadline intervals.
{
    my ($status, $blen, $eof) = run_slow_reader('/buffered', 4.5 * $wt);
    is $status, 200, "buffered: got 200";
    ok $eof, "buffered: clean EOF";
    is $blen, $BODY, "buffered: slow-draining reader got the whole body";
}

# Phase 2: same through the streaming (start_streaming + write) path.
{
    my ($status, $blen, $eof) = run_slow_reader('/streaming', 4.5 * $wt);
    is $status, 200, "streaming: got 200";
    ok $eof, "streaming: clean EOF";
    is $blen, $BODY, "streaming: slow-draining reader got the whole body";
}

# Phase 3: a peer that drains NOTHING must still be reaped (that is what
# write_timeout is for; drain-refresh bounds it at three intervals).  Wait 5
# intervals without reading, then drain: if the reaper fired, the server
# never wrote more than the kernel buffers absorbed (~1.2MB << 3MB).
{
    my $s = make_client('/buffered');
    my ($data, $eof) = ('', 0);
    my $cv = AE::cv;
    my ($start, $io, $watchdog);
    my $finish = sub { undef $start; undef $io; undef $watchdog; $eof = $_[0]; $cv->send };
    $start = AE::timer 5 * $wt, 0, sub {
        $io = AE::io $s, 0, sub {
            while (1) {
                my $n = $s->sysread(my $buf, 65536);
                if (!defined $n) { return if $!{EAGAIN} || $!{EWOULDBLOCK}; return $finish->(0) }
                return $finish->(1) if $n == 0;
                $data .= $buf;
            }
        };
    };
    $watchdog = AE::timer 60 * TIMEOUT_MULT, 0, sub { $finish->(0) };
    $cv->recv;
    close $s;
    my (undef, $body) = split /\r\n\r\n/, $data, 2;
    my $blen = defined $body ? length $body : 0;
    ok $eof, "stuck: connection was closed (reaper still fires)";
    cmp_ok $blen, '<', $BODY, "stuck: response was cut short ($blen < $BODY)";
}
