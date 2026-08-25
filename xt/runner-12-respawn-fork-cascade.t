#!perl
# A worker forked while another slot has a respawn backoff timer pending must
# not inherit that timer (EV timers survive fork): firing it in the worker
# forks grandchildren in a cascade and leaves the worker non-accepting.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use POSIX ();
use lib 't'; use Utils;

plan skip_all => "fork-tree inspection needs a Unix ps" if $^O eq q{MSWin32};
# Some minimal containers ship no procps at all, and without it the walk below
# silently sees an empty tree and every count reads 0.
plan skip_all => "ps(1) not available"
    unless do { my $ok = open my $p, q{-|}, q{ps}, q{-eo}, q{pid=}; close $p if $ok; $ok };
plan tests => 4;

my $PRE_FORK = 4;

my $dir    = tempdir(CLEANUP => 1);
my $countf = "$dir/boot_attempts";
open my $cf, '>', $countf or die "open $countf: $!";
print $cf "0";
close $cf;

my (undef, $port) = get_listen_socket();

my $master = fork;
die "fork: $!" unless defined $master;

if (!$master) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen   => ["localhost:$port"],
            pre_fork => $PRE_FORK,
            quiet    => 1,
            # Transient boot failure that heals: the first $PRE_FORK workers
            # exit immediately (arming a backoff timer per slot); every worker
            # after that starts normally.
            after_fork => sub {
                open my $fh, '+<', $countf or return;
                flock($fh, LOCK_EX) or return;
                my $n = do { local $/; <$fh> } || 0;
                seek $fh, 0, 0;
                truncate $fh, 0;
                print $fh $n + 1;
                close $fh;
                POSIX::_exit(1) if $n < $PRE_FORK;
            },
            app => sub { $_[0]->send_response(200, [], ["pid=$$\n"]) },
        )->run;
    };
    POSIX::_exit(0);
}

# Let the initial deaths, the backoff timers and any cascade play out.
sleep 6 * TIMEOUT_MULT;

# Walk the master's whole descendant tree.
my %kids;
if (open my $ps, '-|', 'ps', '-eo', 'pid=,ppid=') {
    while (<$ps>) {
        my ($p, $pp) = /(\d+)\s+(\d+)/ or next;
        push @{ $kids{$pp} }, $p;
    }
    close $ps;
}

my @tree;
my @queue = ($master);
while (@queue) {
    my $p = shift @queue;
    push @tree, $p;
    push @queue, @{ $kids{$p} || [] };
}
shift @tree;    # drop the master itself

my $direct = scalar @{ $kids{$master} || [] };

# Depth of the deepest descendant, measured from the master.
my %ppid_of;
for my $pp (keys %kids) { $ppid_of{$_} = $pp for @{ $kids{$pp} } }
my $depth = 0;
for my $p (@tree) {
    my ($d, $c) = (0, $p);
    while ($c != $master && $d < 20) { $c = $ppid_of{$c} // $master; $d++ }
    $depth = $d if $d > $depth;
}

is scalar(@tree), $PRE_FORK,
    "exactly $PRE_FORK descendants after the transient boot failure"
    or diag "descendant pids: @tree";
is $direct, $PRE_FORK, "all $PRE_FORK are direct children of the master";
is $depth, 1, "no grandchildren (a cascade nests supervisors)";

reap_server($master);
my $status = $?;
kill 'KILL', $_ for @tree;

is $status & 127, 0, "master shut down without a signal";
