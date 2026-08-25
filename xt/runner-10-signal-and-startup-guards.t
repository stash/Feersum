#!perl
# run() handles INT as well as QUIT/TERM (a setsid'd master only ever gets INT
# by pid; unhandled it orphans the workers on the port), and an app file
# returning a truthy non-coderef fails at startup instead of answering 500.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 12;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use File::Spec;

$| = 1;   # this test forks a lot; keep TAP ordered and visible if it wedges
my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir = tempdir(CLEANUP => 1);

sub write_app {
    my ($name, $body) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $body;
    close $fh or die "close $path: $!";
    return $path;
}

sub port_is_bound {
    my ($port) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 2);
    return $s ? do { close $s; 1 } : 0;
}

# Can we still bind the port ourselves?  That is the operator-visible symptom:
# an orphaned worker holding it makes the restart fail with EADDRINUSE.
sub port_is_free {
    my ($port) = @_;
    my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port,
                                  Proto => 'tcp', Listen => 5, ReuseAddr => 1);
    return $s ? do { close $s; 1 } : 0;
}

#####################################################################
# 1. SIGINT to a pre_fork master must take the whole pool down.
#####################################################################
{
    my $app = write_app('int.feersum',
        'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }');
    my (undef, $port) = get_listen_socket();

    my $master = fork // die "fork: $!";
    if (!$master) {
        # Detach from the harness's pipes.  If this regression reappears the
        # workers are orphaned rather than reaped, and orphans holding the TAP
        # stdout pipe open make prove hang instead of reporting a failure.
        open STDOUT, '>', '/dev/null' or POSIX::_exit(2);
        open STDERR, '>', '/dev/null' or POSIX::_exit(2);
        require Feersum::Runner;
        eval {
            Feersum::Runner->new(
                listen => ["127.0.0.1:$port"], app_file => $app,
                pre_fork => 2, quiet => 1,
            )->run();
        };
        POSIX::_exit(0);
    }

    select undef, undef, undef, 1.5 * TIMEOUT_MULT;
    ok port_is_bound($port), "pre_fork master is serving on $port";

    kill 'INT', $master or die "kill INT: $!";

    my $reaped = 0;
    for (1 .. 40 * TIMEOUT_MULT) {
        select undef, undef, undef, 0.15;
        $reaped = 1, last if waitpid($master, POSIX::WNOHANG()) == $master;
    }
    ok $reaped, "master exited on SIGINT";

    # workers get a moment to notice the process-group signal
    my $free = 0;
    for (1 .. 40 * TIMEOUT_MULT) {
        select undef, undef, undef, 0.15;
        $free = 1, last if port_is_free($port);
    }
    ok $free, "port released - no worker orphaned holding the listen socket"
        or diag "port $port still held; workers were orphaned to init";

    kill 'KILL', $master;   # belt and braces
    waitpid $master, POSIX::WNOHANG();
}

#####################################################################
# 2. A non-coderef app must fail at startup, not bind and 500.
#####################################################################
for my $case (['hashref', 'return { not => "code" };'],
              ['string',  'return "definitely not code";']) {
    my ($name, $src) = @$case;
    my $app = write_app("notcode-$name.feersum", $src);
    my (undef, $port) = get_listen_socket();

    my $pid = fork // die "fork: $!";
    if (!$pid) {
        open STDERR, '>', '/dev/null' or POSIX::_exit(2);
        require Feersum::Runner;
        eval {
            Feersum::Runner->new(
                listen => ["127.0.0.1:$port"], app_file => $app, quiet => 1,
            )->run();
            1;
        } or POSIX::_exit(29);
        POSIX::_exit(0);
    }

    my $status;
    for (1 .. 40 * TIMEOUT_MULT) {
        select undef, undef, undef, 0.15;
        if (waitpid($pid, POSIX::WNOHANG()) == $pid) { $status = $?; last }
    }
    if (!defined $status) {
        kill 'KILL', $pid; waitpid $pid, 0;
        fail "non-coderef app ($name): startup did not exit";
    }
    else {
        isnt $status, 0, "non-coderef app ($name): startup failed, exit != 0";
    }
}

#####################################################################
# 3. after_fork that dies must fail the worker, not leave it serving
#    half-initialised.  On the respawn path EV swallowed the exception.
#####################################################################
{
    my $app = write_app('af.feersum',
        'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"ok\n") }');
    my (undef, $port) = get_listen_socket();

    my $master = fork // die "fork: $!";
    if (!$master) {
        open STDERR, '>', '/dev/null' or POSIX::_exit(2);
        require Feersum::Runner;
        eval {
            Feersum::Runner->new(
                listen => ["127.0.0.1:$port"], app_file => $app,
                pre_fork => 1, quiet => 1,
                after_fork => sub { die "after_fork boom\n" },
            )->run();
        };
        POSIX::_exit(0);
    }

    select undef, undef, undef, 2.0 * TIMEOUT_MULT;
    # Every worker dies in after_fork, so nothing may ever answer a request.
    my $answered = 0;
    for (1 .. 3) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1);
        if ($s) {
            syswrite $s, "GET / HTTP/1.0\015\012\015\012";
            my $r = '';
            eval { local $SIG{ALRM} = sub { die }; alarm 2;
                   while (sysread($s, my $b, 4096)) { $r .= $b } alarm 0 };
            close $s;
            $answered = 1 if $r =~ m{^HTTP/1\.[01] 200};
        }
        select undef, undef, undef, 0.3;
    }
    ok !$answered, "worker whose after_fork died never serves traffic";

    kill 'QUIT', $master;
    my $gone = 0;
    for (1 .. 40 * TIMEOUT_MULT) {
        select undef, undef, undef, 0.15;
        $gone = 1, last if waitpid($master, POSIX::WNOHANG()) == $master;
    }
    kill 'KILL', $master unless $gone;
    waitpid $master, POSIX::WNOHANG();
    ok 1, "master shut down after after_fork failures";
}

#######################################################################
# --daemonize --hot-restart must not report success when startup fails: the
# listen sockets are bound before the daemonizing fork, so a port in use is a
# non-zero exit with a message, not a clean start with nothing listening.
#######################################################################
{
    my $app = write_app('bindfail.feersum',
        'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"ok\n") }');

    # Occupy a port so the bind must fail.
    my $blocker = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', Listen => 5, ReuseAddr => 1)
        or die "blocker: $!";
    my $busy = $blocker->sockport;

    my %exit;
    for my $mode ('plain', 'hot') {
        my @extra = $mode eq 'hot' ? ('--hot-restart') : ();
        my $devnull = File::Spec->devnull;
        my $pid = fork;
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            open STDERR, '>', $devnull;
            open STDOUT, '>', $devnull;
            exec $^X, '-Mblib', 'bin/feersum', '--native',
                 '--listen', "127.0.0.1:$busy", '--daemonize',
                 '--pid-file', "$dir/$mode-bindfail.pid", @extra, $app
                or POSIX::_exit(127);
        }
        waitpid $pid, 0;
        $exit{$mode} = $? >> 8;
    }
    close $blocker;

    isnt $exit{plain}, 0, "daemonize: bind failure is reported (exit $exit{plain})";
    isnt $exit{hot}, 0,
        "daemonize + hot_restart: bind failure is reported (exit $exit{hot})";
}

#######################################################################
# --daemonize must not report success when the app fails to load: a readiness
# pipe carries the child's verdict back to the parent before it exits.
#######################################################################
{
    my $bad = write_app('badsyntax.feersum', 'this is not valid perl ((((');
    my $good = write_app('goodstart.feersum',
        'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"ok\n") }');

    my ($sock, $port) = get_listen_socket();
    close $sock;
    my $devnull = File::Spec->devnull;

    my $run = sub {
        my ($app, @extra) = @_;
        my $pid = fork;
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            open STDERR, '>', $devnull;
            open STDOUT, '>', $devnull;
            exec $^X, '-Mblib', 'bin/feersum', '--native',
                 '--listen', "127.0.0.1:$port", '--daemonize',
                 '--pid-file', "$dir/rdy.pid", @extra, $app
                or POSIX::_exit(127);
        }
        waitpid $pid, 0;
        return $? >> 8;
    };

    isnt $run->($bad), 0,
        'daemonize: a broken app file is reported, not exit 0';

    # ...and a good app must still start cleanly, or the handshake has broken
    # daemonization itself.
    my $rc = $run->($good);
    is $rc, 0, 'daemonize: a working app still starts successfully';
    if ($rc == 0 && -e "$dir/rdy.pid") {
        open my $fh, '<', "$dir/rdy.pid";
        my $srv = <$fh>; chomp $srv; close $fh;
        ok port_is_bound($port), 'daemonize: the started daemon is listening';
        kill 'QUIT', $srv if $srv;
        waitpid $srv, 0 if $srv;
    }
    else { ok 0, 'daemonize: the started daemon is listening' }
}
