#!perl
# Tests for hot_restart failure paths:
# 1. Bad app_file on SIGHUP -> rollback to old generation
# 2. max_requests_per_worker -> worker auto-recycles
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 18;
use utf8;
use lib 't'; use Utils;
use File::Temp qw(tempfile tempdir);
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

# Safety net: these children are setsid'd session leaders, so nothing else ever
# reaps them.  Any die between fork and the explicit kill below would otherwise
# strand a daemon still bound to the test port.
my @_kill_on_exit;
END { kill 'QUIT', @_kill_on_exit if $$ == $parent_pid && @_kill_on_exit }

sub http_get {
    my ($port, $timeout) = @_;
    $timeout //= 3 * TIMEOUT_MULT;
    my $body;
    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/', port => $port,
        timeout => $timeout, sub {
            my ($b, $h) = @_;
            $body = $b if $h->{Status} == 200;
            $cv->send; undef $cli;
        };
    $cv->recv;
    return $body;
}

sub extract_pid   { ($_[0] // '') =~ /\bpid=(\d+)/        ? $1 : undef }
sub extract_ident { ($_[0] // '') =~ /\bident=([\d.]+)/    ? $1 : undef }

# Worker app body: emits pid + a per-process hires startup ident so
# generations can be distinguished even when the kernel recycles a PID.
my $APP = q{
    use feature 'state';
    use Time::HiRes ();
    sub {
        my $r = shift;
        state $ident = sprintf "%d.%06d.%d", Time::HiRes::gettimeofday(), $$;
        $r->send_response(200, ['Content-Type'=>'text/plain'], \"pid=$$ ident=$ident\n");
    }
};

###############################################################################
# Test 1: SIGHUP with bad app_file -> old generation stays
###############################################################################

my $dir = tempdir(CLEANUP => 1);
my $app_file = "$dir/app.feersum";

# Write a good app first
open my $fh, '>', $app_file or die;
print $fh $APP;
close $fh;

my (undef, $port) = get_listen_socket();

my $master = fork;
push @_kill_on_exit, $master if $master;
die "fork: $!" unless defined $master;
if (!$master) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen      => ["localhost:$port"],
            app_file    => $app_file,
            hot_restart => 1,
            quiet       => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

my $body1 = http_get($port);
ok $body1, "gen1 responds";
my $gen1_pid = extract_pid($body1);
my $gen1_ident = extract_ident($body1);
ok $gen1_pid, "got gen1 pid";

# Break the app file
open $fh, '>', $app_file or die;
print $fh 'die "intentional failure"';
close $fh;

# SIGHUP -> new gen fails -> old gen should still serve
kill 'HUP', $master;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $body2 = http_get($port);
ok $body2, "server still responds after failed reload";
my $gen2_ident = extract_ident($body2);
is $gen2_ident, $gen1_ident, "same gen serving (rollback worked)";

# Restore good app and reload again
open $fh, '>', $app_file or die;
print $fh $APP;
close $fh;

kill 'HUP', $master;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $body3 = http_get($port);
ok $body3, "new gen responds after fix";
my $gen3_ident = extract_ident($body3);
isnt $gen3_ident, $gen1_ident, "new gen has different identity";

reap_server($master);
is $? & 127, 0, "master shut down cleanly";

###############################################################################
# Test 2: max_requests_per_worker -> worker auto-recycles
###############################################################################

my ($fh2, $app2) = tempfile(SUFFIX => '.feersum', UNLINK => 1);
print $fh2 $APP;
close $fh2;

my (undef, $port2) = get_listen_socket();

my $master2 = fork;
push @_kill_on_exit, $master2 if $master2;
die "fork: $!" unless defined $master2;
if (!$master2) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen                  => ["localhost:$port2"],
            app_file                => $app2,
            pre_fork                => 1,
            max_requests_per_worker => 3,
            quiet                   => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# Send 3 requests to hit the max
my $first_ident;
for my $i (1..3) {
    my $b = http_get($port2);
    $first_ident //= extract_ident($b);
}

# Wait for worker recycle (timer checks every 1s)
select undef, undef, undef, 3.0 * TIMEOUT_MULT;

my $body4 = http_get($port2);
ok $body4, "server responds after worker recycle";
my $new_ident = extract_ident($body4);
ok $new_ident, "got new worker ident";
isnt $new_ident, $first_ident, "worker was recycled (different identity)";

reap_server($master2);
is $? & 127, 0, "master2 shut down cleanly";
