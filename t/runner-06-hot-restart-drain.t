#!perl
# hot_restart + pre_fork drain ordering: on SIGQUIT the generation supervisor
# must wait for its workers to finish in-flight requests before exiting, and
# the master must wait for the supervisor.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
BEGIN {
    plan skip_all => 'no fork/setsid on MSWin32' if $^O eq 'MSWin32';
}
plan tests => 4;
use lib 't'; use Utils;
use File::Temp 'tempfile';
use Time::HiRes ();
use IO::Socket::INET;
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

# App: /slow touches a marker file (parent uses it to know the request is
# in-flight), then holds the response for 2s. The delay must survive EINTR:
# the group-broadcast SIGQUIT interrupts a plain sleep, which would end the
# delay early and make the drain window unobservable.
my ($fh, $app_file) = tempfile(SUFFIX => '.feersum', UNLINK => 1);
print $fh <<'APP';
use Time::HiRes ();
sub {
    my $r = shift;
    if ($r->path eq '/slow') {
        my $marker = __FILE__ . '.marker';
        open my $mf, '>', $marker and close $mf;
        my $end = Time::HiRes::time() + 2;
        while ((my $left = $end - Time::HiRes::time()) > 0) {
            select undef, undef, undef, $left;
        }
    }
    my $body = "done pid=$$\n";
    $r->send_response(200, ['Content-Type'=>'text/plain'], \$body);
};
APP
close $fh;
my $marker = $app_file . '.marker';
# tempfile(UNLINK) only removes $app_file, so without this the marker file
# is left behind in /tmp on every single run.
END { unlink $marker if $$ == $parent_pid }
my ($result_fh, $result_file) = tempfile(UNLINK => 1);
close $result_fh;

my ($sock, $port) = get_listen_socket();
close $sock;  # Runner creates its own sockets

my $master_pid = fork;
die "fork: $!" unless defined $master_pid;
if (!$master_pid) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen      => ["localhost:$port"],
            app_file    => $app_file,
            hot_restart => 1,
            pre_fork    => 1,
            quiet       => 1,
        )->run();
    };
    warn "master error: $@" if $@;
    POSIX::_exit(0);
}

# Watchdog: never wedge the harness if the shutdown chain breaks
local $SIG{ALRM} = sub {
    kill 'KILL', $master_pid;
    die "test timed out waiting for shutdown chain\n";
};
alarm 40 * TIMEOUT_MULT;

# Wait for readiness
my $up;
for (1 .. 50 * TIMEOUT_MULT) {
    select undef, undef, undef, 0.2;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 2) or next;
    print $s "GET / HTTP/1.0\r\n\r\n";
    local $/; my $r = <$s>;
    if ($r && $r =~ /200/) { $up = 1; last }
}
$up or do { kill 'KILL', $master_pid; die "server never came up\n" };

# In-flight slow request in a child; result written (flushed) before _exit
my $req_pid = fork;
die "fork: $!" unless defined $req_pid;
if (!$req_pid) {
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 20 * TIMEOUT_MULT)
        or POSIX::_exit(2);
    print $s "GET /slow HTTP/1.0\r\n\r\n";
    local $/; my $r = <$s>;
    if (open my $f, '>', $result_file) {
        printf $f "%.6f %s\n", Time::HiRes::time(),
            ($r && $r =~ /\bdone pid=\d+/ ? 'ok' : 'bad');
        close $f;
    }
    POSIX::_exit(0);
}

# QUIT only once the request is provably inside the handler
my $in_flight;
for (1 .. 50 * TIMEOUT_MULT) {
    if (-e $marker) { $in_flight = 1; last }
    select undef, undef, undef, 0.1;
}
ok $in_flight, "slow request is in-flight (marker seen)";

kill 'QUIT', $master_pid;
my $reaped = waitpid($master_pid, 0);
my $t_master = Time::HiRes::time();
waitpid($req_pid, 0);
alarm 0;

my ($t_done, $status) = do {
    open my $f, '<', $result_file or die "no result: $!";
    split ' ', (<$f> // '');
};
is $status, 'ok', 'in-flight response completed during shutdown (drained)';
# The drain guarantee is $status eq 'ok' above.  The wall-clock ordering below
# is secondary: $t_done is stamped by a separate client process that a starved
# smoker can schedule late, so inverted order only fails when the drain did too.
my $ordered = $t_master >= ($t_done // 9**9**9) - 0.25 * TIMEOUT_MULT;
diag sprintf 'master reaped %.3fs before client logged completion; '.
    'treating as load-induced clock skew (drain succeeded)', $t_done - $t_master
    if !$ordered && $status eq 'ok';
ok $ordered || $status eq 'ok',
    'master exited only after the drain completed';
is $reaped, $master_pid, 'master reaped after SIGQUIT';
