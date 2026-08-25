#!perl
# A sendfile response whose file shrinks mid-transfer sends a body short of the
# committed Content-Length; the connection must then close, not reuse keepalive
# and glue the next pipelined response inside the promised body.
# Author-only: needs sendfile blocked mid-transfer while the file is truncated.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use IO::Socket::INET ();
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep);

BEGIN {
    plan skip_all => 'sendfile() is only supported on Linux' unless $^O eq 'linux';
}
plan tests => 3;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/big.bin";
my $SIZE = 32 * 1024 * 1024;               # too big to drain into one socket buffer
{ open my $fh, '>', $file or die $!;
  print $fh 'A' x (1024*1024) for 1 .. 32; close $fh }

my ($lsock, $port) = get_listen_socket();
my $spid = fork // die "fork: $!";
if (!$spid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new;
    $f->set_keepalive(1);
    $f->use_socket($lsock);
    my $bomb;
    $f->request_handler(sub {
        my $r = shift;
        if ($r->env->{PATH_INFO} eq '/second') {
            $r->send_response(200, ['Content-Type'=>'text/plain'], \"SECOND-RESPONSE-BODY");
            return;
        }
        open my $fh, '<', $file or die $!;
        my $w = $r->start_streaming(200, ['Content-Length' => $SIZE]);
        $w->sendfile($fh);
        close $fh;
        $w->close;
        # truncate once sendfile is surely blocked on a full socket buffer
        $bomb = EV::timer(0.3 * TIMEOUT_MULT, 0, sub { truncate($file, 100_000) });
    });
    EV::run;
    POSIX::_exit(0);
}
close $lsock;

my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
    Timeout => 5 * TIMEOUT_MULT) or die "connect: $!";
# pipeline both requests, then read the headers of #1 and pause so sendfile
# blocks with the socket buffer full while the file is truncated underneath
$c->syswrite("GET /big HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\n\r\n");

my $buf = '';
$c->blocking(0);
my $declared;
my $deadline = time + 10 * TIMEOUT_MULT;
# read headers of response 1
while (time < $deadline) {
    my $n = sysread($c, my $b, 65536);
    if (defined $n && $n > 0) { $buf .= $b; last if $buf =~ /\r\n\r\n/ }
    sleep 0.05;
}
($declared) = $buf =~ /Content-Length:\s*(\d+)/i;
is $declared, $SIZE, "response 1 committed the full Content-Length" or diag $buf;

my $hdr_end = index($buf, "\r\n\r\n") + 4;
sleep 1.2 * TIMEOUT_MULT;                   # let the truncate land while blocked

# drain the rest to EOF
while (time < $deadline) {
    my $n = sysread($c, my $b, 65536);
    if (defined $n) { last if $n == 0; $buf .= $b; next }
    last unless $!{EAGAIN} || $!{EWOULDBLOCK};
    sleep 0.05;
}
close $c;

my $body_bytes = length($buf) - $hdr_end;
cmp_ok $body_bytes, '<', $SIZE,
    "body was cut short of the committed length ($body_bytes < $SIZE)";

# the fix: the connection closes after the short body.  Pre-fix it was reused and
# the /second response was written straight into the promised body.
unlike substr($buf, $hdr_end), qr/SECOND-RESPONSE-BODY/,
    "no pipelined response glued inside the short body (keepalive dropped)"
    or diag "DESYNC: response 2 appeared inside response 1's declared body";

kill 'QUIT', $spid; waitpid $spid, 0;
