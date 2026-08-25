#!perl
# seek() must stop at the end of the request body, exactly as read() does.
# Without the clamp, seeking past a short body chopped into a pipelined next
# request: it was either eaten whole (client hangs to read_timeout) or left
# partial, so the parser answered 400 and closed.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use Time::HiRes qw(time);
use IO::Socket::INET;
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);
use POSIX ();
use lib 't'; use Utils;

use Feersum;

plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
plan tests => 9;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

my $evh = Feersum->new();
$evh->use_socket($socket);
$evh->set_keepalive(1);
$evh->read_timeout(4 * TIMEOUT_MULT);

my $seek_mode = 'exact';
$evh->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '';
    if ($p eq '/one') {
        my $in = $env->{'psgi.input'};
        if    ($seek_mode eq 'exact') { $in->seek(5,   SEEK_CUR) }
        elsif ($seek_mode eq 'over')  { $in->seek(100, SEEK_CUR) }
        elsif ($seek_mode eq 'end')   { $in->seek(-3,  SEEK_END) }
    }
    return [200, ['Content-Type' => 'text/plain', 'X-Path' => $p], ["ok\n"]];
});

# A 5-byte body with a second request pipelined immediately behind it.
sub pipelined_exchange {
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                      Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT);
        POSIX::_exit(1) unless $s;
        $s->autoflush(1);
        syswrite($s, "POST /one HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nABCDE"
                   . "GET /two HTTP/1.1\r\nHost: h\r\n\r\n");
        my $r = '';
        my $deadline = time + 6 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $rin = ''; vec($rin, fileno($s), 1) = 1;
            last unless select(my $ro = $rin, undef, undef, 1.5 * TIMEOUT_MULT);
            my $n = sysread($s, my $b, 65536);
            last if !defined $n || $n == 0;
            $r .= $b;
            last if (() = $r =~ /^HTTP\/1\.1 /mg) >= 2;
        }
        close $s;
        my @st = $r =~ /^HTTP\/1\.1 (\d+)/mg;
        # exit code carries the outcome: 0 = two 200s, else a failure shape
        POSIX::_exit(0) if @st == 2 && $st[0] == 200 && $st[1] == 200;
        POSIX::_exit(2);
    }

    my $cv = AE::cv;
    my $status;
    my $t  = AE::timer(12 * TIMEOUT_MULT, 0, sub { kill 'KILL', $pid; $cv->send });
    my $cw = AE::child($pid, sub { $status = $_[1] >> 8; $cv->send });
    $cv->recv;
    waitpid $pid, 0;
    return $status;
}

for my $case (['exact', 'seek to exactly the body end'],
              ['over',  'seek past the body end'],
              ['end',   'SEEK_END measured from the body end']) {
    my ($mode, $desc) = @$case;
    $seek_mode = $mode;
    my $rc = pipelined_exchange();
    is $rc, 0, "$desc: both pipelined requests answered 200";
}

# The clamp must not break ordinary in-body seeking.
{
    $seek_mode = 'none';
    my $got;
    $evh->psgi_request_handler(sub {
        my $env = shift;
        my $in = $env->{'psgi.input'};
        $in->seek(5, SEEK_SET);
        my $body = '';
        $in->read($body, 100);
        $got = $body;
        return [200, ['Content-Type' => 'text/plain'], ["ok\n"]];
    });

    my $cv = AE::cv;
    my $cli; $cli = simple_client POST => '/', port => $port,
        headers => { 'Content-Type' => 'text/plain' },
        body => 'HELLOworld', timeout => 5 * TIMEOUT_MULT,
        sub { $cv->send; undef $cli };
    $cv->recv;
    is $got, 'world', 'in-body SEEK_SET still skips exactly the requested bytes';
}

# A body-less GET: nothing to seek over, and no pipelined data to eat.
{
    my ($ret_zero, $ret_over);
    $evh->psgi_request_handler(sub {
        my $env = shift;
        my $in = $env->{'psgi.input'};
        $ret_zero = $in->seek(0, SEEK_CUR);
        $ret_over = $in->seek(50, SEEK_CUR);
        return [200, ['Content-Type' => 'text/plain'], ["ok\n"]];
    });
    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/', port => $port,
        timeout => 5 * TIMEOUT_MULT, sub { $cv->send; undef $cli };
    $cv->recv;
    ok defined $ret_zero, 'seek(0) on a body-less request returns defined';
    ok defined $ret_over, 'seek past a body-less request returns defined';
}

$evh->unlisten;
