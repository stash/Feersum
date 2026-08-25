#!perl
# A Content-Length body delivered across many reads with a small final segment
# is not rejected with 413 when max_body_len > max_read_buf: max_read_buf
# bounds header/chunked accumulation, not declared-body reception.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More tests => 2;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;
use Socket qw(SOMAXCONN);

my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', ReuseAddr => 1, Proto => 'tcp',
    Listen => SOMAXCONN, Blocking => 0,
) or die "listen: $!";
my $port = $sock->sockport;

my $f = Feersum->endjinn;
$f->use_socket($sock);
$f->max_read_buf(64 * 1024);        # 64 KiB read-buffer cap
$f->max_body_len(8 * 1024 * 1024);  # 8 MiB body allowance (> max_read_buf)
$f->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    $env->{'psgi.input'}->read($body, $env->{CONTENT_LENGTH})
        if $env->{CONTENT_LENGTH};
    $r->send_response(200, ['Content-Type' => 'text/plain'],
        ["got=" . length($body)]);
});

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    EV::default_loop()->loop_fork;
    my $life = EV::timer(30 * TIMEOUT_MULT, 0, sub { EV::break });
    EV::run;
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/94b watchdog timeout\n" };
alarm 60 * TIMEOUT_MULT;

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# 200000 is not a multiple of 8192: the final read is a 3392-byte remainder
# that lands SvCUR within READ_BUFSZ of expected_cl.  The trigger depends on
# SvGROW not over-allocating past expected_cl, so on page-rounding allocators
# this is only a non-regression check.
my $bodylen = 200_000;
my $cl = IO::Socket::INET->new(
    PeerAddr => "127.0.0.1:$port", Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
) or die "connect: $!";
$cl->autoflush(1);
syswrite $cl, "POST / HTTP/1.1\r\nHost: localhost\r\n"
    . "Content-Length: $bodylen\r\nConnection: close\r\n\r\n";
my $chunk = 'x' x 8192;
my $sent = 0;
while ($sent < $bodylen) {
    my $want = $bodylen - $sent < 8192 ? $bodylen - $sent : 8192;
    my $n = syswrite($cl, $chunk, $want);
    last unless $n;
    $sent += $n;
    select undef, undef, undef, 0.003 * TIMEOUT_MULT;   # gap -> distinct reads
}
is $sent, $bodylen, 'full body written to server';

my $resp = '';
eval { local $/; $resp = <$cl>; };
close $cl;
like $resp // '', qr{^HTTP/1\.1 200.*got=200000}s,
    'drip-fed Content-Length body within max_body_len accepted (no spurious 413)';

alarm 0;
reap_server($pid);
