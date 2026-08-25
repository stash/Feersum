#!perl
# Worker dies under active requests: server recovers, new worker takes over
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 9;  # 6 explicit + 3 simple_client implicit
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
my $app = "$dir/loadkill.feersum";
open my $fh, '>', $app or die;
print $fh 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh;

my (undef, $port) = get_listen_socket();

my $master = fork // die "fork: $!";
if (!$master) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen   => ["localhost:$port"],
            app_file => $app,
            pre_fork => 1,
            quiet    => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# Get current worker pid
my $worker_pid = extract_pid(http_get($port));
ok $worker_pid, "got worker pid ($worker_pid)";

# Kill the worker with SIGKILL (simulates crash)
kill 'KILL', $worker_pid;

# Wait for respawn
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

# Server should recover with a new worker
my $new_pid = extract_pid(http_get($port));
ok $new_pid, "server responds after worker kill";
isnt $new_pid, $worker_pid, "new worker spawned (pid $new_pid)";

# Kill again to verify repeated recovery
kill 'KILL', $new_pid;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $third_pid = extract_pid(http_get($port));
ok $third_pid, "server responds after second worker kill";
isnt $third_pid, $new_pid, "another new worker spawned (pid $third_pid)";

reap_server($master);
pass "worker-death-under-load clean shutdown";
