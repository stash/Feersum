#!perl
# run_client's timeout must not orphan a client that ignores SIGQUIT
# (inherited from make-test shells): it escalates to SIGKILL.
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use POSIX ();

plan tests => 3;

my $dir = tempdir(CLEANUP => 1);
my $pidfile = "$dir/client.pid";

{
    local $ENV{PERL_TEST_TIME_OUT_FACTOR} = 0.2;
    # run_client's own checks must fail here; the reap below is the assertion
    Test::More->builder->todo_start('timeout is forced by design');
    run_client 'quitting-ignored client', sub {
        $SIG{QUIT} = 'IGNORE';
        open my $fh, '>', $pidfile or exit(98);
        print $fh "$$\n";
        close $fh;
        sleep 30;
        exit(0);
    };
    Test::More->builder->todo_end;
}

my $cpid = do {
    open my $fh, '<', $pidfile or die "no pid file: $!";
    my $p = <$fh>; close $fh; chomp $p; $p;
};
for (1 .. 40) {
    waitpid($cpid, POSIX::WNOHANG());
    last unless kill(0, $cpid);
    select undef, undef, undef, 0.05;
}
my $gone = !kill(0, $cpid);
if (!$gone) { kill 'KILL', $cpid; waitpid($cpid, 0) }
ok $gone, 'timed-out client ignoring SIGQUIT was reaped, not orphaned';
