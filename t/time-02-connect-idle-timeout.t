#!perl
# read_timeout closes a connection that is accepted but never starts a request,
# even with header_timeout disabled.  Uses a Unix-domain socket so accept fires
# immediately (TCP_DEFER_ACCEPT would let the kernel hold a zero-byte TCP conn).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::UNIX;
use Socket qw(SOMAXCONN);
use File::Temp qw(tempdir);

BEGIN {
    plan skip_all => 'no AF_UNIX' unless eval { IO::Socket::UNIX->can('new') };
}
plan tests => 3;

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/feer.sock";
my $sock = IO::Socket::UNIX->new(
    Local => $path, Type => SOCK_STREAM(), Listen => SOMAXCONN,
) or die "listen unix: $!";
$sock->blocking(0);

my $f = Feersum->endjinn;
$f->use_socket($sock);
$f->header_timeout(0);            # disable the Slowloris header deadline
$f->read_timeout(2 * TIMEOUT_MULT);
$f->set_proxy_protocol(1);        # a fresh conn starts in RECEIVE_PROXY_HEADER
$f->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], ['ok']);
});

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    EV::default_loop()->loop_fork;
    my $life = EV::timer(30 * TIMEOUT_MULT, 0, sub { EV::break });
    EV::run;
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/08b watchdog\n" };
alarm 30 * TIMEOUT_MULT;
select undef, undef, undef, 1.0 * TIMEOUT_MULT;

sub unix_client { IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM())
    or die "connect unix: $!" }

# 1. Zero-byte connect-and-idle: the read timer armed at accept must fire
# (header_timeout is off), timing out the PROXY-header phase with a 408.
{
    my $cl = unix_client();
    my $t0 = time;
    my $resp = eval {
        local $SIG{ALRM} = sub { die "no timeout - connection hung\n" };
        alarm 12 * TIMEOUT_MULT;
        local $/;
        my $r = <$cl>;
        alarm 0;
        $r;
    };
    my $elapsed = time - $t0;
    close $cl;
    like $resp // ($@ || ''), qr{408},
        "zero-byte idle connection timed out with 408 (took ${elapsed}s)";
    cmp_ok $elapsed, '<=', 6 * TIMEOUT_MULT,
        "timeout fired near read_timeout, not at the alarm (${elapsed}s)";
}

# 2. Partial PROXY header then stall: same read-timeout PROXY branch.
{
    my $cl = unix_client();
    $cl->autoflush(1);
    syswrite $cl, "PROXY TCP4 192.0.2.1 192.0.2.2 ";   # partial v1 header
    my $resp = eval {
        local $SIG{ALRM} = sub { die "no timeout - connection hung\n" };
        alarm 12 * TIMEOUT_MULT;
        local $/;
        my $r = <$cl>;
        alarm 0;
        $r;
    };
    close $cl;
    like $resp // ($@ || ''), qr{408},
        'stalled partial PROXY header timed out with 408';
}

alarm 0;
reap_server($pid);
