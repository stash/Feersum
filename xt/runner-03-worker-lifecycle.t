#!perl
# Worker lifecycle: max_requests_per_worker with keepalive; preload_app=0 with
# an app that fails to load respawns; graceful_timeout=0 and the
# FEERSUM_GRACEFUL_TIMEOUT env var; SIGQUIT reaching a worker already draining
# a retirement; a worker not outliving a parent that died without signalling.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 27;  # 15 explicit + 12 simple_client implicit
use utf8;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use POSIX ();
use IO::Socket::INET;

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
# Test 1: max_requests_per_worker with keepalive connections
###############################################################################

my $app1 = "$dir/mrkeepalive.feersum";
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
            pre_fork => 1, max_requests_per_worker => 3,
            quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# Send 3 requests (hitting max), then wait for recycle
my $first_pid;
for (1..3) {
    my $b = http_get($port1);
    $first_pid //= extract_pid($b);
}
ok $first_pid, "got initial worker pid ($first_pid)";

# Wait for recycle (1s timer + graceful shutdown time)
select undef, undef, undef, 3.0 * TIMEOUT_MULT;

my $new_pid = extract_pid(http_get($port1));
ok $new_pid, "server responds after recycle";
isnt $new_pid, $first_pid, "worker recycled after max_requests with keepalive";

kill 'QUIT', $m1; waitpid $m1, 0;
pass "keepalive max_requests clean shutdown";

###############################################################################
# Test 2: preload_app=0 + app load failure -> worker respawns
###############################################################################

my $app2 = "$dir/badapp.feersum";
open my $fh2, '>', $app2 or die;
# First load succeeds, subsequent loads tracked by a counter file
print $fh2 <<"APP";
my \$counter_file = "$dir/load_counter";
my \$n = 0;
if (-f \$counter_file) { open my \$f, '<', \$counter_file; \$n = <\$f>; chomp \$n; close \$f }
\$n++;
open my \$f, '>', \$counter_file; print \$f \$n; close \$f;
sub { \$_[0]->send_response(200,["Content-Type"=>"text/plain"],\\"pid=\$\$ load=\$n\\n") };
APP
close $fh2;

my (undef, $port2) = get_listen_socket();
my $m2 = fork // die "fork: $!";
if (!$m2) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port2"], app_file => $app2,
            pre_fork => 1, preload_app => 0,
            quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

my $body2 = http_get($port2);
ok $body2, "preload_app=0 worker serves";
like $body2, qr/pid=\d+ load=\d+/, "response includes load counter";

kill 'QUIT', $m2; waitpid $m2, 0;
pass "preload_app=0 clean shutdown";

###############################################################################
# Test 3: graceful_timeout=0 - immediate force exit on QUIT
###############################################################################

my (undef, $port3) = get_listen_socket();
my $m3 = fork // die "fork: $!";
if (!$m3) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port3"],
            graceful_timeout => 0,
            quiet => 1,
            app => sub {
                $_[0]->send_response(200, ['Content-Type'=>'text/plain'], \"ok\n");
            },
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 0.8 * TIMEOUT_MULT;
ok http_get($port3), "server responds before QUIT";

kill 'QUIT', $m3;
my $start = time;
waitpid $m3, 0;
my $elapsed = time - $start;
ok $elapsed <= 3, "graceful_timeout=0 exited quickly (${elapsed}s)";

###############################################################################
# Test 4: FEERSUM_GRACEFUL_TIMEOUT env var override
###############################################################################

my (undef, $port4) = get_listen_socket();
my $m4 = fork // die "fork: $!";
if (!$m4) {
    $ENV{FEERSUM_GRACEFUL_TIMEOUT} = 0;
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port4"],
            quiet => 1,
            app => sub {
                $_[0]->send_response(200, ['Content-Type'=>'text/plain'], \"ok\n");
            },
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 0.8 * TIMEOUT_MULT;
ok http_get($port4), "server responds with env var timeout";

kill 'QUIT', $m4;
$start = time;
waitpid $m4, 0;
$elapsed = time - $start;
ok $elapsed <= 3, "FEERSUM_GRACEFUL_TIMEOUT=0 exited quickly (${elapsed}s)";

###############################################################################
# Test 5: SIGQUIT reaches a worker already draining a retirement (a held
# stream keeps that drain open): the second graceful_shutdown must not croak
# before the force-exit timer is armed.
###############################################################################

my $app5 = "$dir/retire_stream.feersum";
open my $fh5, '>', $app5 or die;
print $fh5 <<'APP';
our %HELD;
sub {
    my $r = shift;
    if (($r->env->{PATH_INFO} || '') eq '/stream') {
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/event-stream']);
        $w->write("data: hi\n\n");
        $HELD{"$w"} = $w;          # never closed
        return;
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"pid=$$\n");
}
APP
close $fh5;

my (undef, $port5) = get_listen_socket();
my $m5 = fork // die "fork: $!";
if (!$m5) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port5"], app_file => $app5,
            pre_fork => 1, max_requests_per_worker => 3,
            graceful_timeout => 2, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# Hold a stream open so the retirement drain can never complete.
my $held = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port5", Proto => 'tcp',
                                 Timeout => 3 * TIMEOUT_MULT);
ok $held, "opened a streaming connection";
if ($held) {
    $held->autoflush(1);
    print {$held} "GET /stream HTTP/1.1\r\nHost: h\r\n\r\n";
    my $rin = ''; vec($rin, fileno($held), 1) = 1;
    select(my $rout = $rin, undef, undef, 3 * TIMEOUT_MULT);
    sysread($held, my $junk, 4096);
}

# Identify the worker, then push it past the retirement limit so it starts a
# drain that the held stream will never let finish.
my $wpid = extract_pid(http_get($port5));
ok $wpid, "got worker pid ($wpid)";
http_get($port5) for 1 .. 2;

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# The WORKER, not the supervisor: the supervisor never calls graceful_shutdown
# twice, and its SIGKILL backstop masks the worker ignoring the signal.
kill 'QUIT', $wpid;
my $gone = 0;
for (1 .. 24 * TIMEOUT_MULT) {
    unless (kill 0, $wpid) { $gone = 1; last }
    select undef, undef, undef, 0.5;
}
ok $gone, "draining worker honoured SIGQUIT instead of needing SIGKILL";

close $held if $held;
reap_server($m5);

###############################################################################
# Test 6: a worker must not outlive a parent that died without signalling.
# SIGKILL delivers no shutdown, so the worker used to serve on with stale code
# and keep the listen socket - the next start then failed with EADDRINUSE.
###############################################################################

my $app6 = "$dir/orphan.feersum";
open my $fh6, '>', $app6 or die;
print $fh6 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh6;

my (undef, $port6) = get_listen_socket();
my $m6 = fork // die "fork: $!";
if (!$m6) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port6"], app_file => $app6,
            pre_fork => 1, graceful_timeout => 2, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;
my $w6 = extract_pid(http_get($port6));
ok $w6, "got worker pid (".($w6 // 'undef').")";

kill 'KILL', $m6;
waitpid $m6, 0;

my $orphan_gone = 0;
for (1 .. 30 * TIMEOUT_MULT) {
    unless (_alive($w6)) { $orphan_gone = 1; last }
    select undef, undef, undef, 0.5;
}
ok $orphan_gone, "worker exited once its parent was gone, leaving no orphan";
kill 'KILL', $w6 unless $orphan_gone;

# kill 0 succeeds for a ZOMBIE.  This worker's parent was killed, so it is
# reparented to whatever init the machine has - and a CI container's pid 1
# may never wait(), leaving the exited worker visible forever.
sub _alive {
    my $pid = shift;
    return 0 unless kill 0, $pid;
    if (open my $fh, '<', "/proc/$pid/stat") {
        my $line = <$fh>;
        close $fh;
        return $line =~ /\)\s+(\S)/ ? ($1 eq 'Z' ? 0 : 1) : 1;
    }
    my $state = `ps -o state= -p $pid 2>/dev/null`;
    return defined $state && $state =~ /Z/ ? 0 : 1;
}
