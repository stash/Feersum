#!perl
# access_log emits each entry when its response is flushed, with the request's
# own service time, not one request late on a keepalive connection.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use EV;
use IO::Socket::INET;
use POSIX ();

plan tests => 8;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

my @log;
is $feer->access_log(sub { push @log, [@_] }), $feer->access_log(),
    "access_log setter returns the callback";

$feer->psgi_request_handler(sub {
    my $b = 'ok';
    return [200, ['Content-Length' => length $b], [$b]];
});

# Three requests on ONE keepalive connection, spaced well apart.  The gap is
# what the old implementation reported as the elapsed time.
my $GAP = 0.4;
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    select undef, undef, undef, 0.3 * TMULT;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
    ) or POSIX::_exit(9);
    for my $i (1 .. 3) {
        syswrite($s, "GET /req$i HTTP/1.1\015\012Host: l\015\012\015\012") or last;
        my $r = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 5 * TMULT;
            while ($r !~ /\015\012\015\012ok/s) {
                my $n = sysread($s, my $b, 4096);
                last unless $n;
                $r .= $b;
            }
            alarm 0;
        };
        select undef, undef, undef, $GAP;
    }
    close $s;
    POSIX::_exit(0);
}

my $done = AE::cv;
my $w = AE::child($pid, sub { $done->send });
my $guard = AE::timer 20 * TMULT, 0, sub { $done->send };
$done->recv;

# The connection is closed by now, but the point is that all three lines were
# emitted as each response completed - not batched at connection close.
is scalar(@log), 3, "one log line per request"
    or diag explain \@log;

for my $i (0 .. 2) {
    my $n = $i + 1;
    is +($log[$i] ? $log[$i][1] : "(missing)"), "/req$n",
        "line $n is for /req$n, in order";
}

# Each request is served in ~a millisecond.  Pre-fix these read ~$GAP, because
# the guard fired when the NEXT request replaced it.
my @slow = grep { defined $_->[2] && $_->[2] > $GAP / 2 } @log;
is scalar(@slow), 0, "elapsed is the request's own service time, not the gap"
    or diag "elapsed values: " . join(', ', map { $_->[2] } @log);

is $log[0][0], 'GET', "method is passed through";
