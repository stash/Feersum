#!perl
# A HUP while a restart backoff is armed must not hand that timer to the new
# generation: EV timers survive fork, so it would run the master.s restart logic.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use POSIX ();

BEGIN {
    plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
    plan skip_all => 'needs a POSIX fork' unless $Config::Config{d_fork}
        || eval { require Config; $Config::Config{d_fork} };
}
plan tests => 6;

use_ok('Feersum::Runner');

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

# A stale socket file left by a previous run is unlinked and rebound.
{
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/stale.sock";
    my $stale = IO::Socket::UNIX->new(Local => $path, Listen => 1)
        or die "cannot create stale socket: $!";
    close $stale;
    ok -S $path, 'stale socket file exists';
    my $r = bless { backlog => 128 }, 'Feersum::Runner';
    my $sock = eval { $r->_create_socket($path, 0, 1) };
    ok $sock, 'stale unix socket is unlinked and rebound' or diag $@;
    close $sock if $sock;
}

# HUP while a restart backoff is pending.
{
    my $dir = tempdir(CLEANUP => 1);
    my ($app, $flag, $logf) = ("$dir/app.feersum", "$dir/fixed", "$dir/master.log");
    open my $ah, '>', $app or die $!;
    # Separate event-loop batches from the ready signal, but under RESPAWN_INSTANT_DEATH.
    print $ah "if (!-e '$flag') {\n",
              "    \$Feersum::Runner::_bomb = EV::timer(0.2, 0, sub { POSIX::_exit(7) });\n",
              "}\n",
              "sub { \$_[0]->send_response(200, [\"Content-Type\"=>\"text/plain\"], \\\"ok\") }\n";
    close $ah;

    my (undef, $port) = get_listen_socket();
    my $master = fork // die "fork: $!";
    if (!$master) {
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

    sub slurp_log {
        open my $lh, '<', $logf or return '';
        local $/; my $t = <$lh> // ''; close $lh; return $t;
    }

    my $saw_backoff = 0;
    for (1 .. 60) {
        select undef, undef, undef, 0.1 * TIMEOUT_MULT;
        last if $saw_backoff = (slurp_log() =~ /restarting in \S+s \(failure 1\)/ ? 1 : 0);
    }

    if ($saw_backoff) {
        open my $fh, '>', $flag or die $!; close $fh;  # the app is healthy now
        kill 'HUP', $master;
        select undef, undef, undef, 5 * TIMEOUT_MULT;  # let any inherited timer fire
    }

    kill 'QUIT', $master if kill 0, $master;
    for (1 .. 40) { select undef, undef, undef, 0.1 * TIMEOUT_MULT;
        last if waitpid($master, POSIX::WNOHANG()) > 0 }
    kill 'KILL', $master if kill 0, $master;

    my $log = slurp_log();

  SKIP: {
        skip 'generation died in the same event-loop batch as its ready signal, '
           . 'so the master took the failed-start path and armed no backoff for '
           . 'the HUP to race', 3
            unless $saw_backoff;
        pass 'master armed a restart backoff after the generation died';

        # master-only bookkeeping: a generation pid here inherited the restart timer
        my %restarters;
        $restarters{$1}++ while $log =~ /Feersum \[(\d+)\]: active generation died/g;
        delete $restarters{$master};
        is_deeply [sort keys %restarters], [],
        'only the master runs generation-restart bookkeeping'
        or diag "non-master pids restarting: @{[sort keys %restarters]}\nlog:\n$log";

        my %loads;
        $loads{$1}++ while $log =~ /gen (\d+) loading app/g;
        my @dup = sort grep { $loads{$_} > 1 } keys %loads;
        is_deeply \@dup, [],
            'no generation number was loaded twice'
        or diag "duplicated generations: @dup\nlog:\n$log";
    }
}
