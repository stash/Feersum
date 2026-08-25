#!perl
# pid_file + hot_restart: verify pid_file contains master PID
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 12;  # 10 explicit + 2 simple_client implicit
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

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/pidapp.feersum";
open my $fh, '>', $app or die;
print $fh 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh;

my $pid_file = "$dir/feersum.pid";
my (undef, $port) = get_listen_socket();

my $master = fork // die "fork: $!";
if (!$master) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen      => ["localhost:$port"],
            app_file    => $app,
            hot_restart => 1,
            pid_file    => $pid_file,
            quiet       => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

# pid_file should exist and contain the master pid
ok -f $pid_file, "pid_file created";
my $file_pid = do { open my $f, '<', $pid_file; local $/; <$f> };
chomp($file_pid //= '');
is $file_pid, $master, "pid_file contains master pid ($master)";

# Verify the serving generation has a DIFFERENT pid
my $body = http_get($port);
ok $body, "server responds";
my ($gen_pid) = ($body // '') =~ /pid=(\d+)/;
isnt $gen_pid, $master, "generation pid ($gen_pid) differs from master ($master)";

# After HUP, pid_file should still contain master pid (unchanged)
kill 'HUP', $master;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $body2 = http_get($port);
ok $body2, "responds after HUP";

my $file_pid2 = do { open my $f, '<', $pid_file; local $/; <$f> };
chomp($file_pid2 //= '');
# pid_file was written at startup by the master, not updated on HUP - still master pid
is $file_pid2, $master, "pid_file still contains master pid after HUP";

reap_server($master);
unlink $pid_file;
pass "pid_file+hot_restart clean shutdown";

###############################################################################
# A daemonized start that fails must not leave the pid file its own
# writability probe created: zero bytes still satisfies `test -f`, so a start
# that failed reads to a health check as one that worked.
###############################################################################

my $dir2 = tempdir(CLEANUP => 1);
my ($pf_fail, $broken) = ("$dir2/fail.pid", "$dir2/broken.psgi");
open my $bfh, '>', $broken or die "open $broken: $!";
print $bfh "this is not valid perl (((";
close $bfh;

my $rc = system($^X, (map { "-I$_" } @INC[0 .. 2]), '-e', <<"CODE");
use Feersum::Runner;
Feersum::Runner->new(listen => ['127.0.0.1:0'], daemonize => 1,
    pid_file => '$pf_fail', app_file => '$broken', quiet => 1)->run;
CODE
isnt $rc, 0, "a daemonized start with an unloadable app reports failure";
ok !-e $pf_fail, "no pid file left behind by the failed start";

# The same probe must not delete a pid file that was already there - it may
# belong to a server that is running right now.
my $pf_keep = "$dir2/keep.pid";
open my $kfh, '>', $pf_keep or die "open $pf_keep: $!";
print $kfh "99999\n";
close $kfh;
system($^X, (map { "-I$_" } @INC[0 .. 2]), '-e', <<"CODE");
use Feersum::Runner;
Feersum::Runner->new(listen => ['127.0.0.1:0'], daemonize => 1,
    pid_file => '$pf_keep', app_file => '$broken', quiet => 1)->run;
CODE
my $kept = do { open my $f, '<', $pf_keep or die "pid file was removed: $!";
                local $/; <$f> };
chomp($kept //= '');
is $kept, '99999', "a pre-existing pid file survives someone else's failed start";
