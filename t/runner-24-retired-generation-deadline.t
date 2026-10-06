#!perl
# Block an app timer without listeners to isolate generation supervision.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum::Runner;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);

sub slurp {
    open my $fh, '<', $_[0] or return '';
    local $/;
    return <$fh> // '';
}

sub await {
    my ($cb, $seconds) = @_;
    my $end = time + $seconds;
    while (time < $end) { return 1 if $cb->(); sleep 0.02 }
    return 0;
}

# A force-killed retired worker zombifies until something reaps it; under a
# non-reaping container PID 1 (common on smokers) kill(0) still reports it alive.
# Treat gone OR zombie as not running.
sub not_running {
    my $pid = shift;
    waitpid($pid, POSIX::WNOHANG());           # reap it if it reparented to us
    return 1 unless kill 0, $pid;              # truly gone
    if (open my $st, '<', "/proc/$pid/stat") { # Linux: a zombie is dead
        my $state = (split ' ', scalar(<$st> // ''))[2] // '';
        return 1 if $state eq 'Z';
    }
    return 0;
}

my @scenarios = ('retirement deadline', 'shutdown during retirement',
                 'another reload during retirement', 'failed replacement during retirement');
for my $scenario (0 .. $#scenarios) {
    subtest $scenarios[$scenario] => sub {
        my $dir = tempdir(CLEANUP => 1);
        open my $app, '>', "$dir/app.pl" or die $!;
        print {$app} "sub { }\n";
        close $app;
        open my $script, '>', "$dir/master.pl" or die $!;
        print {$script} <<'MASTER';
use strict;
use warnings;
use Feersum::Runner;
use POSIX ();
{
    package RetirementRunner;
    our @ISA = ('Feersum::Runner');
    sub _hot_restart_bind {
        $_[0]->{_master_socks} = [];
        $_[0]->{_listen_addrs} = [];
    }
}
my ($dir, $scenario, $tmult) = @ARGV;
my $wedge;
RetirementRunner->new(hot_restart => 1, app_file => "$dir/app.pl",
    quiet => 0, graceful_timeout => 0.1 * $tmult,
    startup_timeout => 5 * $tmult, after_fork => sub {
        open my $pids, '>>', "$dir/pids" or die $!;
        print {$pids} "$$\n"; close $pids;
        if (-e "$dir/first") {
            $wedge = EV::timer(0.02, 0.02, sub {
                POSIX::_exit(7) if -e "$dir/crash";
            }) if $scenario == 3;
            return;
        }
        open my $first, '>', "$dir/first" or die $!; close $first;
        $wedge = EV::timer(0.1 * $tmult, 0, sub {
            open my $entered, '>', "$dir/entered" or die $!;
            print {$entered} $$; close $entered;
            while (1) { select undef, undef, undef, 60 }
        });
    })->run;
POSIX::_exit(0);
MASTER
        close $script;
        my $master = fork // die "fork: $!";
        if (!$master) {
            open STDERR, '>', "$dir/master.log" or die $!;
            exec($^X, '-Mblib', "$dir/master.pl", $dir, $scenario, TMULT)
                or POSIX::_exit(127);
        }
        my $reaped = 0;
        my $cleanup = guard {
            my @pids = split /\n/, slurp("$dir/pids");
            kill 'KILL', @pids if @pids;
            unless ($reaped) { kill 'KILL', $master; waitpid $master, 0 }
        };
        ok await(sub { slurp("$dir/master.log") =~ /master ready/ && -s "$dir/entered" },
                 5 * TMULT), 'first generation is ready and blocked'
            or diag slurp("$dir/master.log");
        my $old = slurp("$dir/entered");
        die 'first generation did not block' unless $old =~ /^\d+$/;
        sleep 1.1 * TMULT if $scenario == 3;
        kill 'HUP', $master;
        ok await(sub { slurp("$dir/master.log") =~ /retiring old/ }, 5 * TMULT),
            'replacement is ready';
        if ($scenario == 2) {
            kill 'HUP', $master;
            ok await(sub { slurp("$dir/master.log") =~ /gen 3 ready \(pid .*retiring old/ },
                     5 * TMULT), 'another replacement starts while the first still drains';
        }
        if ($scenario == 1 || $scenario == 3) {
            if ($scenario == 1) {
                kill 'QUIT', $master;
            } else {
                open my $broken, '>', "$dir/app.pl" or die $!;
                print {$broken} "die 'broken replacement';\n"; close $broken;
                open my $crash, '>', "$dir/crash" or die $!; close $crash;
            }
            ok await(sub {
                if (waitpid($master, POSIX::WNOHANG()) == $master) { $reaped = 1; return 1 }
                return 0;
            }, 10 * TMULT), 'master exits within the shutdown budget';
            ok not_running($old), 'master leaves no retired generation running';
            like slurp("$dir/master.log"), qr/restarting in .*failure 1/,
                'reload resets the generation lifetime used for crash backoff'
                if $scenario == 3;
        } else {
            ok await(sub { not_running($old) }, 10 * TMULT),
                'master enforces the retired generation deadline';
            ok kill(0, $master), 'replacement remains supervised';
            if ($scenario == 2) {
                my @pids = split /\n/, slurp("$dir/pids");
                ok kill(0, $pids[-1]), 'latest generation survives inherited deadlines';
            }
            kill 'QUIT', $master;
            ok await(sub {
                if (waitpid($master, POSIX::WNOHANG()) == $master) { $reaped = 1; return 1 }
                return 0;
            }, 5 * TMULT), 'master shuts down normally';
        }
        undef $cleanup;
        done_testing;
    };
}
done_testing;
