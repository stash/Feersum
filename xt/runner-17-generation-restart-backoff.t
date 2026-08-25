#!perl
# A hot_restart generation that comes up and crashes at once, repeatedly, must
# not have the master re-fork as fast as it can load the app: generation
# restarts use the worker respawn backoff.  Author-only: timing-shaped.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp ();
use POSIX ();

BEGIN {
    plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
    plan skip_all => 'needs a POSIX fork' unless $Config::Config{d_fork}
        || eval { require Config; $Config::Config{d_fork} };
}
plan tests => 1;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir = File::Temp::tempdir(CLEANUP => 1);
my $app = "$dir/gen.feersum";
open my $ah, '>', $app or die $!;
# The bomb timer lives in a global so it outlives the do().
print $ah <<'APP'; close $ah;
$Feersum::Runner::_x115_bomb = EV::timer(0.02, 0, sub { POSIX::_exit(7) });
sub { $_[0]->send_response(200, ["Content-Type"=>"text/plain"], \"ok") }
APP

my (undef, $port) = get_listen_socket();
my $logf = "$dir/master.log";

my $pid = fork // die "fork: $!";
if (!$pid) {
    open STDOUT, '>', "$dir/master.out";
    open STDERR, '>', $logf;
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["127.0.0.1:$port"], app_file => $app,
            hot_restart => 1, quiet => 0, startup_timeout => 5 * TIMEOUT_MULT,
        )->run;
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 5 * TIMEOUT_MULT;
kill 'KILL', $pid if kill 0, $pid;
waitpid $pid, 0;

my $log = ''; if (open my $lh, '<', $logf) { local $/; $log = <$lh> // ''; close $lh }

# Each generation logs "loading app" once.
my $forks = () = $log =~ /loading app/g;
cmp_ok $forks, '<', 20,
    "master does not spin re-forking a crash-looping generation ($forks forks)"
    or diag "log tail:\n" . substr($log, -1200);
