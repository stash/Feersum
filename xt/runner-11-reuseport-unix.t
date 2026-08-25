#!perl
# reuseport with a UNIX listener: UNIX sockets are inherited rather than
# rebound (a rebind unlinks the previous worker's path), so the parent, master
# and generation must keep those fds open at their _socks indices for respawns.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use Socket qw(SO_REUSEPORT);
use IO::Socket::UNIX;
use File::Temp qw(tempdir);
use POSIX ();

plan skip_all => "SO_REUSEPORT not available"
    unless eval { my $v = SO_REUSEPORT(); defined $v };
plan tests => 6;

$| = 1;
my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

# sun_path is 108 bytes - keep well clear of the long scratchpad path.
my $dir = tempdir(DIR => '/tmp', CLEANUP => 1);

sub write_app {
    my ($name, $src) = @_;
    my $path = "$dir/$name";
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $src;
    close $fh or die "close $path: $!";
    return $path;
}

# Ask over the UNIX socket; returns the body, or undef.
sub unix_get {
    my ($path, $timeout) = @_;
    $timeout ||= 3 * TIMEOUT_MULT;
    my $s = IO::Socket::UNIX->new(Peer => $path, Timeout => $timeout) or return undef;
    print {$s} "GET /x HTTP/1.0\015\012\015\012";
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        while (sysread($s, my $b, 4096)) { $r .= $b }
        alarm 0;
    };
    close $s;
    return undef unless $r =~ m{^HTTP/1\.[01] 200};
    my ($body) = $r =~ /\015\012\015\012(.*)/s;
    return $body;
}

sub spawn {
    my (%o) = @_;
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        open STDOUT, '>', '/dev/null' or POSIX::_exit(2);
        open STDERR, '>', "$dir/$o{log}" or POSIX::_exit(2);
        require Feersum::Runner;
        eval { Feersum::Runner->new(%{ $o{args} })->run() };
        POSIX::_exit(0);
    }
    return $pid;
}

sub reap {
    my ($pid) = @_;
    kill 'QUIT', $pid;
    for (1 .. 40 * TIMEOUT_MULT) {
        select undef, undef, undef, 0.15;
        return if waitpid($pid, POSIX::WNOHANG()) == $pid;
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
}

my $app = write_app('ru.feersum',
    'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }');

#####################################################################
# 1. A worker killed under reuseport+UNIX must be replaced.
#####################################################################
{
    my $sock = "$dir/a.sock";
    my $pid  = spawn(log => 'a.log', args => {
        listen => [$sock], app_file => $app,
        pre_fork => 2, reuseport => 1, quiet => 1,
    });
    select undef, undef, undef, 2.0 * TIMEOUT_MULT;

    my $first = unix_get($sock);
    ok defined $first, "reuseport+unix: serving before the kill"
        or diag "log: " . `cat $dir/a.log 2>&1`;

    my ($wpid) = ($first || '') =~ /pid=(\d+)/;
    kill 'KILL', $wpid if $wpid;
    select undef, undef, undef, 2.0 * TIMEOUT_MULT;

    my $after;
    for (1 .. 10 * TIMEOUT_MULT) {
        $after = unix_get($sock);
        last if defined $after;
        select undef, undef, undef, 0.3;
    }
    ok defined $after, "reuseport+unix: still serving after a worker was killed"
        or diag "log: " . `cat $dir/a.log 2>&1`;
    reap($pid);
}

#####################################################################
# 2. max_requests_per_worker retires workers constantly - the pool must
#    survive it (no crash needed to hit the bug).
#####################################################################
{
    my $sock = "$dir/b.sock";
    my $pid  = spawn(log => 'b.log', args => {
        listen => [$sock], app_file => $app,
        pre_fork => 2, reuseport => 1, quiet => 1,
        max_requests_per_worker => 2,
    });
    select undef, undef, undef, 2.0 * TIMEOUT_MULT;

    my $ok = 0;
    for (1 .. 12) { $ok++ if defined unix_get($sock) }
    cmp_ok $ok, '>=', 10, "reuseport+unix: survives worker retirement ($ok/12 served)"
        or diag "log: " . `cat $dir/b.log 2>&1`;
    reap($pid);
}

#####################################################################
# 3. hot_restart + reuseport + UNIX served nothing at all.
#####################################################################
{
    my $sock = "$dir/c.sock";
    my $pid  = spawn(log => 'c.log', args => {
        listen => [$sock], app_file => $app,
        pre_fork => 2, reuseport => 1, quiet => 1, hot_restart => 1,
    });
    select undef, undef, undef, 3.0 * TIMEOUT_MULT;

    my $before = unix_get($sock);
    ok defined $before, "hot_restart+reuseport+unix: serving"
        or diag "log: " . `cat $dir/c.log 2>&1`;

    kill 'HUP', $pid;
    select undef, undef, undef, 3.0 * TIMEOUT_MULT;

    my $after;
    for (1 .. 15 * TIMEOUT_MULT) {
        $after = unix_get($sock);
        last if defined $after;
        select undef, undef, undef, 0.3;
    }
    ok defined $after, "hot_restart+reuseport+unix: serving after SIGHUP"
        or diag "log: " . `cat $dir/c.log 2>&1`;
    reap($pid);
}

#####################################################################
# 4. Mixed TCP + UNIX: one bad entry must not take the TCP listener down.
#####################################################################
{
    my $sock = "$dir/d.sock";
    my (undef, $port) = get_listen_socket();
    my $pid = spawn(log => 'd.log', args => {
        listen => ["127.0.0.1:$port", $sock], app_file => $app,
        pre_fork => 2, reuseport => 1, quiet => 1,
    });
    select undef, undef, undef, 2.0 * TIMEOUT_MULT;

    my $unix_ok = defined unix_get($sock);
    my $tcp_ok  = 0;
    for (1 .. 10 * TIMEOUT_MULT) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 2);
        if ($s) {
            print {$s} "GET /x HTTP/1.0\015\012\015\012";
            my $r = '';
            eval { local $SIG{ALRM} = sub { die }; alarm 3;
                   while (sysread($s, my $b, 4096)) { $r .= $b } alarm 0 };
            close $s;
            $tcp_ok = 1, last if $r =~ m{^HTTP/1\.[01] 200};
        }
        select undef, undef, undef, 0.3;
    }
    ok $unix_ok && $tcp_ok,
        "mixed tcp+unix under reuseport: both listeners serve (tcp=$tcp_ok unix=" .
        ($unix_ok ? 1 : 0) . ")"
        or diag "log: " . `cat $dir/d.log 2>&1`;
    reap($pid);
}
