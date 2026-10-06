#!perl
# hot_restart without pre_fork: a clean worker retirement (exit 42) is not a
# crash and must recycle immediately, never escalating the respawn backoff.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

plan tests => 2;

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/app.feersum";
open my $fh, '>', $app or die "open $app: $!";
print {$fh} q{sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],"pid=$$") }};
close $fh or die "close $app: $!";

my $lsn = IO::Socket::INET->new(LocalAddr => '127.0.0.1:0', Proto => 'tcp',
    Listen => 16) or die "listen: $!";
my $port = $lsn->sockport;
close $lsn;

my $errfile = "$dir/stderr.log";
my $m = fork // die "fork: $!";
if (!$m) {
    open STDERR, '>', $errfile or POSIX::_exit(2);
    require Feersum::Runner;
    Feersum::Runner->new(listen => ["127.0.0.1:$port"], app_file => $app,
        hot_restart => 1, max_requests_per_worker => 2, quiet => 0)->run();
    POSIX::_exit(0);
}

my $ready;
for (1 .. 30 * TIMEOUT_MULT) {
    if (defined get_pid()) { $ready = 1; last }
    select undef, undef, undef, 0.2;
}
die "supervisor never came up\n" unless $ready;

sub get_pid {
    my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
        Timeout => 5 * TIMEOUT_MULT) or return undef;
    syswrite $c, "GET / HTTP/1.0\r\nHost: x\r\n\r\n";
    my $buf = '';
    while (length($buf) < 4000) {
        my $n = sysread($c, my $ch, 4096);
        last unless defined $n && $n > 0;
        $buf .= $ch;
    }
    close $c;
    return $1 if $buf =~ /pid=(\d+)/;
    return undef;
}

my %pids;
for (1 .. 14) {
    my $p = get_pid();
    $pids{$p}++ if defined $p;
    select undef, undef, undef, 0.3;
}
kill 'QUIT', $m;
eval {
    local $SIG{ALRM} = sub { die "reap timeout\n" };
    alarm 10 * TIMEOUT_MULT;
    waitpid $m, 0;
    alarm 0;
};
alarm 0;
if (kill 0, $m) { kill 'KILL', $m; waitpid $m, 0 }

open my $efh, '<', $errfile or die "open $errfile: $!";
my $err = do { local $/; <$efh> };
my @fails = ($err =~ /failure (\d+)/g);

cmp_ok scalar(keys %pids), '>=', 5, 'generations recycle under the request cap';
is scalar(@fails), 0, 'retirements are not crash-counted'
    or diag "backoff failures seen: @fails";
