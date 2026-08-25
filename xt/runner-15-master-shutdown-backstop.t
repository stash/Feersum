#!perl
# The hot_restart master keeps the graceful_timeout promise: a generation
# wedged inside app code (never back in its event loop) is force-killed at the
# deadline so the listen sockets are released for the next start.
# The wedge must retry its blocking select: EV's signal handler interrupts it once.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Time::HiRes ();
use POSIX ();

plan skip_all => 'author test' unless $ENV{FEERSUM_AUTHOR_TESTS} || $ENV{AUTHOR_TESTING};
plan tests => 6;

my $GT  = 2 * TIMEOUT_MULT;          # graceful_timeout
my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/wedge.psgi";
open my $fh, '>', $app or die $!;
print {$fh} <<'APP';
sub {
    my $env = shift;
    while (1) { select undef, undef, undef, 60 }
    return [200, ['Content-Type' => 'text/plain'], ['never']];
};
APP
close $fh;

# Start a Runner, wedge a request in it, QUIT the entry process, and report
# how long it took to go and whether it let go of the port.
sub wedge_and_quit {
    my (%extra) = @_;
    my $lsock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', Listen => 16, ReuseAddr => 1) or die $!;
    my $port = $lsock->sockport;
    close $lsock;

    my $master = fork();
    die "fork: $!" unless defined $master;
    if (!$master) {
        open STDOUT, '>', "$dir/out";
        open STDERR, '>', "$dir/err";
        require Feersum::Runner;
        Feersum::Runner->new(listen => ["127.0.0.1:$port"], app_file => $app,
                             quiet => 1, graceful_timeout => $GT, %extra)->run();
        POSIX::_exit(0);
    }
    select undef, undef, undef, 2.5 * TIMEOUT_MULT;

    my $client = fork();
    die "fork: $!" unless defined $client;
    if (!$client) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                      Timeout => 5 * TIMEOUT_MULT);
        if ($s) { syswrite $s, "GET /wedge HTTP/1.0\r\n\r\n"; sysread $s, my $z, 100 }
        POSIX::_exit(0);
    }
    select undef, undef, undef, 1.5 * TIMEOUT_MULT;

    my $t0 = Time::HiRes::time();
    kill 'QUIT', $master;
    my $gone = 0;
    my $limit = ($GT + 6) * 3;
    while (Time::HiRes::time() - $t0 < $limit) {
        if (waitpid($master, POSIX::WNOHANG) == $master) { $gone = 1; last }
        select undef, undef, undef, 0.1;
    }
    my $took = Time::HiRes::time() - $t0;
    kill 'KILL', $master unless $gone;
    waitpid $master, 0 unless $gone;
    kill 'KILL', $client;
    waitpid $client, 0;

    # Anything still holding the port would make the next start fail.
    my $free = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port,
        Proto => 'tcp', Listen => 4, ReuseAddr => 1) ? 1 : 0;
    system("fuser -k $port/tcp >/dev/null 2>&1") unless $free;
    return ($gone, $took, $free);
}

# --- hot_restart with the default pre_fork=0: the case that had no backstop
{
    my ($gone, $took, $free) = wedge_and_quit(hot_restart => 1);
    ok $gone,
        sprintf('a hot_restart master whose generation is wedged in app code '
              . 'still exits (%.1fs after QUIT)', $took);
    cmp_ok $took, '<', ($GT + 6) * 2,
        sprintf('and it exits on the graceful_timeout budget, not never (%.1fs '
              . 'against graceful_timeout=%d)', $took, $GT);
    ok $free, 'the listen port is released, so a restart will not hit EADDRINUSE';
}

# --- cold start: had a backstop already, must be unchanged
{
    my ($gone, $took, $free) = wedge_and_quit(pre_fork => 1);
    ok $gone, sprintf('cold start still exits when wedged (%.1fs)', $took);
    cmp_ok $took, '<', ($GT + 6) * 2, 'cold start still exits on budget';
    ok $free, 'cold start still releases the port';
}
