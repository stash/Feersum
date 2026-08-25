#!perl
# Edge case tests for hot_restart:
# 1. Rapid HUP debounce
# 2. startup_timeout rollback
# 3. Current gen dies during a failed HUP reload (compound failure)
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 18;  # 12 explicit + 6 http_get/simple_client implicit
use utf8;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

sub http_get {
    my ($port, $timeout) = @_;
    $timeout //= 3 * TIMEOUT_MULT;
    my $body;
    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/', port => $port,
        timeout => $timeout, sub {
            my ($b, $h) = @_;
            $body = $b if $h->{Status} && $h->{Status} == 200;
            $cv->send; undef $cli;
        };
    $cv->recv;
    return $body;
}

sub extract_pid { ($_[0] // '') =~ /^pid=(\d+)/ ? $1 : undef }

my $dir = tempdir(CLEANUP => 1);

###############################################################################
# Test 1: Rapid HUP debounce - 3 HUPs in 100ms, only 1 reload
###############################################################################

my $app1 = "$dir/app1.feersum";
open my $fh1, '>', $app1 or die;
print $fh1 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh1;

my (undef, $port1) = get_listen_socket();
my $m1 = fork // die "fork: $!";
if (!$m1) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port1"], app_file => $app1,
            hot_restart => 1, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;
my $gen1_pid = extract_pid(http_get($port1));
ok $gen1_pid, "gen1 serving (pid $gen1_pid)";

# Rapid-fire 3 HUPs
kill 'HUP', $m1;
select undef, undef, undef, 0.05;
kill 'HUP', $m1;
select undef, undef, undef, 0.05;
kill 'HUP', $m1;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $gen2_pid = extract_pid(http_get($port1));
ok $gen2_pid, "server responds after rapid HUPs";
isnt $gen2_pid, $gen1_pid, "generation changed (reload happened)";

# One more HUP to verify debounce didn't break future reloads
kill 'HUP', $m1;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $gen3_pid = extract_pid(http_get($port1));
ok $gen3_pid, "subsequent HUP still works";
isnt $gen3_pid, $gen2_pid, "another reload succeeded";

kill 'QUIT', $m1; waitpid $m1, 0;
pass "rapid HUP test clean shutdown";

###############################################################################
# Test 2: startup_timeout too short - rollback to old generation
###############################################################################

my $app2 = "$dir/app2.feersum";
open my $fh2, '>', $app2 or die;
# App that sleeps 3s before signaling ready (simulates slow startup)
# The generation child sends USR2 after loading the app, but if the app
# takes too long to load, _wait_for_ready times out.
print $fh2 'sleep 3; sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh2;

# First, start with a good fast app
my $app2_fast = "$dir/app2fast.feersum";
open my $fh2f, '>', $app2_fast or die;
print $fh2f 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh2f;

my (undef, $port2) = get_listen_socket();
my $m2 = fork // die "fork: $!";
if (!$m2) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port2"], app_file => $app2_fast,
            hot_restart => 1, startup_timeout => 1, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;
my $fast_pid = extract_pid(http_get($port2));
ok $fast_pid, "fast gen serving";

# Switch to slow app, HUP should timeout and rollback
symlink $app2, "$dir/app2link.feersum" if !-e "$dir/app2link.feersum";
# Overwrite the app file with a slow one
open my $fh2s, '>', $app2_fast or die;
print $fh2s 'sleep 3; sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh2s;

kill 'HUP', $m2;
select undef, undef, undef, 3.0 * TIMEOUT_MULT;

my $after_pid = extract_pid(http_get($port2));
ok $after_pid, "server still responds after timeout rollback";
is $after_pid, $fast_pid, "old generation kept (rollback worked)";

kill 'QUIT', $m2; waitpid $m2, 0;
pass "startup_timeout rollback clean shutdown";

###############################################################################
# Test 3: current gen dies during a FAILED HUP reload.  The master must not end
# up with nothing serving and no way to recover (it used to hold the port and
# ignore SIGQUIT).
###############################################################################

my $app3 = "$dir/app3.feersum";
open my $fh3, '>', $app3 or die;
print $fh3 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh3;

my (undef, $port3) = get_listen_socket();
my $m3 = fork // die "fork: $!";
if (!$m3) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port3"], app_file => $app3,
            hot_restart => 1, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;
my $gen1_pid3 = extract_pid(http_get($port3));
ok $gen1_pid3, "compound failure: gen1 serving";

# Break the app so the next generation cannot start, but slowly, so the master
# is still inside _wait_for_ready when the running generation is killed.
open $fh3, '>', $app3 or die;
print $fh3 'sleep 2; die "broken\n";';
close $fh3;

kill 'HUP', $m3;
select undef, undef, undef, 0.4 * TIMEOUT_MULT;
kill 'KILL', $gen1_pid3 if $gen1_pid3;  # active gen dies DURING the reload

# With a genuinely broken app there is nothing left to serve, so the master
# must give up and exit rather than wedge.
my $exited = 0;
for (1 .. 60) {
    select undef, undef, undef, 0.25 * TIMEOUT_MULT;
    my $r = waitpid($m3, POSIX::WNOHANG());
    if ($r == $m3 || $r == -1) { $exited = 1; last }
}
ok $exited, "compound failure: master gave up and exited (did not wedge)";
unless ($exited) { kill 'KILL', $m3; waitpid $m3, 0; }
