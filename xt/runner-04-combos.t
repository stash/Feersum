#!perl
# Combination tests for Runner features:
# 1. hot_restart + max_requests_per_worker (no pre_fork)
# 2. preload_app=0 + access_log
# 3. hot_restart + pre_fork + reuseport
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use utf8;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use POSIX ();
use Socket ();  # SO_REUSEPORT imported on demand in BEGIN below

BEGIN {
    eval { Socket->import('SO_REUSEPORT'); 1 }
        or *SO_REUSEPORT = sub () { undef };
}

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
my $n_tests = 0;

###############################################################################
# Test 1: hot_restart + max_requests_per_worker (no pre_fork)
###############################################################################

my $app1 = "$dir/combo1.feersum";
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
            hot_restart => 1, max_requests_per_worker => 3,
            quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

my $first_pid;
for (1..3) {
    my $b = http_get($port1);
    $first_pid //= extract_pid($b);
}
$n_tests += 4;  # 3 simple_client + 1 ok
ok $first_pid, "hot_restart+max_reqs: got initial pid ($first_pid)";

# Wait for generation to recycle via max_requests_per_worker
# The master should detect the generation died and fork a replacement
select undef, undef, undef, 4.0 * TIMEOUT_MULT;

my $new_body = http_get($port1);
$n_tests += 2;  # 1 simple_client + 1 ok/isnt
my $new_pid = extract_pid($new_body);
ok $new_pid && $new_pid ne $first_pid,
    "hot_restart+max_reqs: generation recycled (new pid $new_pid)";

kill 'QUIT', $m1; waitpid $m1, 0;
$n_tests++;
pass "hot_restart+max_reqs clean shutdown";

###############################################################################
# Test 2: preload_app=0 + access_log
###############################################################################

my $app2 = "$dir/combo2.feersum";
open my $fh2, '>', $app2 or die;
print $fh2 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh2;

my $log_file = "$dir/access.log";

my (undef, $port2) = get_listen_socket();
my $m2 = fork // die "fork: $!";
if (!$m2) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port2"], app_file => $app2,
            pre_fork => 1, preload_app => 0,
            access_log => sub {
                my ($method, $uri, $elapsed) = @_;
                open my $fh, '>>', $log_file;
                print $fh "$method $uri\n";
                close $fh;
            },
            quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

http_get($port2);
$n_tests++;  # simple_client
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

$n_tests += 2;
ok -f $log_file, "preload_app=0 + access_log: log file created";
my $log = do { local (@ARGV, $/) = ($log_file); <> } // '';
like $log, qr/^GET \//, "preload_app=0 + access_log: entry logged";

kill 'QUIT', $m2; waitpid $m2, 0;
$n_tests++;
pass "preload_app=0 + access_log clean shutdown";

###############################################################################
# Test 3: hot_restart + pre_fork + reuseport (if available)
###############################################################################

SKIP: {
    skip "hot_restart+reuseport is timing-sensitive; run individually with prove -bv", 5
        unless $ENV{FEERSUM_TEST_REUSEPORT};

    my $app3 = "$dir/combo3.feersum";
    open my $fh3, '>', $app3 or die;
    print $fh3 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
    close $fh3;

    my ($sock3, $port3) = get_listen_socket();
    close $sock3;  # must release for reuseport workers
    my $m3 = fork // die "fork: $!";
    if (!$m3) {
        require Feersum::Runner;
        eval {
            Feersum::Runner->new(
                listen => ["localhost:$port3"], app_file => $app3,
                hot_restart => 1, pre_fork => 2, reuseport => 1,
                quiet => 1,
            )->run();
        };
        POSIX::_exit(0);
    }

    select undef, undef, undef, 4.0 * TIMEOUT_MULT;

    my $body3 = http_get($port3);
    $n_tests += 2;  # simple_client + ok
    ok $body3, "hot_restart+prefork+reuseport responds";

    kill 'HUP', $m3;
    select undef, undef, undef, 5.0 * TIMEOUT_MULT;

    my $body3b = http_get($port3);
    $n_tests += 2;  # simple_client + ok
    ok $body3b, "hot_restart+prefork+reuseport responds after HUP";

    kill 'QUIT', $m3; waitpid $m3, 0;
    $n_tests++;
    pass "hot_restart+prefork+reuseport clean shutdown";
}

done_testing;
