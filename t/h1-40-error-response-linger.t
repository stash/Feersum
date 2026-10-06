#!perl
# Read-path error responses do a lingering close like timer-path ones: after
# a 400 the server drains late upload bytes instead of RSTing them away.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
plan tests => 3;

$SIG{PIPE} = 'IGNORE';

my $dir = tempdir(CLEANUP => 1);
my ($lsn, $port) = get_listen_socket();
ok $lsn, "listen on $port";

# status file, not exit code: the EV loop reaps mid-run children
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    close $lsn;
    my $fail = sub {
        open my $out, '>', "$dir/status" or POSIX::_exit(9);
        print {$out} "FAIL $_[0]\n";
        close $out;
        POSIX::_exit(1);
    };
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto => 'tcp', Timeout => 5 * TMULT) or $fail->("connect: $!");
    syswrite($c, "GET\015\012Host: x\015\012\015\012");
    my ($got, $cl, $h_done) = ('', 0, 0);
    my $deadline = time() + 5 * TMULT;
    while (time() < $deadline) {
        my $rin = '';
        vec($rin, fileno($c), 1) = 1;
        last unless select($rin, undef, undef, $deadline - time());
        my $buf;
        my $r = sysread($c, $buf, 65536);
        if (!$r) { $fail->('eof before full 400'); }
        $got .= $buf;
        if (!$h_done && $got =~ /\015\012\015\012/) {
            $h_done = 1;
            ($cl) = $got =~ /Content-Length:\s*(\d+)/i;
            $cl //= 0;
        }
        if ($h_done) {
            my (undef, $b) = split /\015\012\015\012/, $got, 2;
            last if length($b // '') >= $cl;
        }
    }
    if ($got !~ /^HTTP\/1\.0 400 /) { $fail->("not a 400: $got"); }
    select undef, undef, undef, 0.1;   # the lingering close is armed at flush
    my $chunk = 'z' x 10_000;
    for my $i (1 .. 10) {
        my $w = syswrite($c, $chunk);
        if (!defined $w) { $fail->("write $i failed: $!"); }
    }
    open my $out, '>', "$dir/status" or POSIX::_exit(9);
    print {$out} "OK\n";
    close $out;
    POSIX::_exit(0);
}

my $saw_dispatch = 0;
my $s = Feersum->new();
$s->use_socket($lsn);
$s->request_handler(sub { $saw_dispatch++ });
my $cv = AE::cv;
my $cw = AE::child($pid, sub { $cv->send });
my $t = AE::timer 12 * TMULT, 0, sub { kill 'KILL', $pid; $cv->send };
$cv->recv;
waitpid($pid, 0);

my $status = do {
    open my $fh, '<', "$dir/status" or die "no status file: $!";
    local $/; <$fh>;
};

ok !$saw_dispatch, 'malformed request never dispatched';
is $status, "OK\n", 'late upload drained, no EPIPE/RST';
