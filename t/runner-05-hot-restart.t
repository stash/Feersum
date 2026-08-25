#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 21;  # 16 explicit + 5 simple_client implicit
use utf8;
use lib 't'; use Utils;
use File::Temp 'tempfile';
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

# Safety net: these children are setsid'd session leaders, so nothing else ever
# reaps them.  Any die between fork and the explicit kill below would otherwise
# strand a daemon still bound to the test port.
my @_kill_on_exit;
END { kill 'QUIT', @_kill_on_exit if $$ == $parent_pid && @_kill_on_exit }

# Write a simple app file that returns a unique per-worker identity -
# lets us verify SIGHUP creates a new generation. A raw PID can be
# reused by the kernel when gen1's worker is reaped before gen2 forks,
# so combine PID with a hires startup timestamp.
my ($fh, $app_file) = tempfile(SUFFIX => '.feersum', UNLINK => 1);
print $fh <<'APP';
use feature 'state';
use Time::HiRes ();
sub {
    my $r = shift;
    # `state` initialiser runs on first call per-process, so pre_fork
    # workers each capture their own ident after fork.
    state $ident = sprintf "%d.%06d.%d", Time::HiRes::gettimeofday(), $$;
    my $body = "pid=$$ ident=$ident\n";
    $r->send_response(200, ['Content-Type'=>'text/plain'], \$body);
};
APP
close $fh;

my (undef, $port) = get_listen_socket();

# Helper: HTTP GET, returns body string or undef on failure
sub http_get {
    my ($port, $timeout) = @_;
    $timeout //= 3 * TIMEOUT_MULT;
    my $body;
    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/',
        port => $port,
        timeout => $timeout,
        sub {
            my ($b, $h) = @_;
            $body = $b if $h->{Status} == 200;
            $cv->send;
            undef $cli;
        };
    $cv->recv;
    return $body;
}

# Body: "pid=N ident=<time>.<usec>.<pid>\n"
# PID is for signals; ident is for worker-identity comparison (survives
# PID reuse when gen1's worker is reaped before gen2 forks).
sub extract_pid {
    my $body = shift // return undef;
    return $1 if $body =~ /\bpid=(\d+)/;
    return undef;
}
sub extract_ident {
    my $body = shift // return undef;
    return $1 if $body =~ /\bident=([\d.]+)/;
    return undef;
}

###############################################################################
# Test 1: basic hot_restart - start, serve, SIGHUP reload, SIGQUIT stop
###############################################################################

my $master_pid = fork;
push @_kill_on_exit, $master_pid if $master_pid;
die "fork: $!" unless defined $master_pid;
if (!$master_pid) {
    require Feersum::Runner;
    eval {
        my $runner = Feersum::Runner->new(
            listen       => ["localhost:$port"],
            app_file     => $app_file,
            hot_restart  => 1,
            quiet        => 1,
        );
        $runner->run();
    };
    warn "gen child error: $@" if $@;
    POSIX::_exit(0);
}

# Wait for first generation to be ready
select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# 1-3: first generation responds
my $body1 = http_get($port);
ok $body1, "first generation responds";
my $gen1_pid = extract_pid($body1);
my $gen1_ident = extract_ident($body1);
ok $gen1_pid, "got gen1 worker pid ($gen1_pid)";
isnt $gen1_pid, $master_pid, "gen1 pid differs from master";

# 4: send SIGHUP to trigger reload
kill 'HUP', $master_pid;
select undef, undef, undef, 1.5 * TIMEOUT_MULT;

# 5-7: second generation responds with different identity
my $body2 = http_get($port);
ok $body2, "second generation responds after HUP";
my $gen2_ident = extract_ident($body2);
ok $gen2_ident, "got gen2 worker ident ($gen2_ident)";
isnt $gen2_ident, $gen1_ident, "gen2 ident differs from gen1 (reload happened)";

# 8: graceful shutdown
kill 'QUIT', $master_pid;
my $reaped = waitpid($master_pid, 0);
is $reaped, $master_pid, "master reaped after SIGQUIT";

###############################################################################
# Test 2: hot_restart + pre_fork
###############################################################################

my ($sock2, $port2) = get_listen_socket();
close $sock2;  # Runner creates its own sockets

my $master2_pid = fork;
push @_kill_on_exit, $master2_pid if $master2_pid;
die "fork: $!" unless defined $master2_pid;
if (!$master2_pid) {
    require Feersum::Runner;
    eval {
        my $runner = Feersum::Runner->new(
            listen       => ["localhost:$port2"],
            app_file     => $app_file,
            hot_restart  => 1,
            pre_fork     => 2,
            quiet        => 1,
        );
        $runner->run();
    };
    warn "gen child error: $@" if $@;
    POSIX::_exit(0);
}

# Wait for pre_fork workers to be ready
select undef, undef, undef, 1.5 * TIMEOUT_MULT;

# 9-10: pre_fork generation responds
my $body3 = http_get($port2);
ok $body3, "pre_fork generation responds";
my $pf_pid = extract_pid($body3);
my $pf_ident = extract_ident($body3);
ok $pf_pid, "got pre_fork worker pid ($pf_pid)";

# 11: SIGHUP reload with pre_fork
kill 'HUP', $master2_pid;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $body4 = http_get($port2);
ok $body4, "pre_fork generation responds after HUP";
my $pf2_pid = extract_pid($body4);
my $pf2_ident = extract_ident($body4);
ok $pf2_pid, "got new pre_fork worker pid ($pf2_pid)";
isnt $pf2_ident, $pf_ident, "pre_fork reload changed worker identity";

# Worker respawn: kill the worker, verify server still responds.
# Guard the pid: if the reload above did not complete in time $pf2_pid is
# undef, and `kill 'KILL', undef` croaks (leaking the setsid'd master) on
# modern perls and signals our own process group on older ones.
SKIP: {
    skip "no worker pid from the reload", 0 unless $pf2_pid;
    kill 'KILL', $pf2_pid;
}
select undef, undef, undef, 1.5 * TIMEOUT_MULT;

my $body5 = http_get($port2);
ok $body5, "pre_fork responds after worker kill";
my $pf3_ident = extract_ident($body5);
ok $pf3_ident, "got respawned worker ident ($pf3_ident)";
isnt $pf3_ident, $pf2_ident, "respawned worker has different identity";

# clean shutdown
kill 'QUIT', $master2_pid;
my $reaped2 = waitpid($master2_pid, 0);
is $reaped2, $master2_pid, "pre_fork master reaped after SIGQUIT";
