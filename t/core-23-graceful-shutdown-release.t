#!perl
# graceful_shutdown releases the server's hold on the event loop so EV::run
# runs dry (a shut-down instance must not pin the loop for the rest of the
# process), and a connection busy at shutdown is swept when its response ends.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Time::HiRes ();
use POSIX ();
use Feersum;

plan tests => 5;

my $dir = tempdir(CLEANUP => 1);

# Run $body in a child and report how long it took to exit, or undef if it had
# to be killed.  The loop exiting at all is the property under test, so it
# cannot be measured from inside the same process.
sub run_child {
    my ($limit, $body) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', "$dir/child.out";
        open STDERR, '>', "$dir/child.err";
        $body->();
        POSIX::_exit(0);
    }
    my $t0 = Time::HiRes::time();
    my $waited;
    while (Time::HiRes::time() - $t0 < $limit) {
        my $r = waitpid $pid, POSIX::WNOHANG;
        if ($r == $pid) { $waited = Time::HiRes::time() - $t0; last }
        select undef, undef, undef, 0.05;
    }
    if (!defined $waited) {
        kill 'KILL', $pid;
        waitpid $pid, 0;
    }
    return $waited;
}

# --- 1: the loop must run dry once the shutdown completes
{
    my ($sock, $port) = get_listen_socket();
    ok $sock, 'listen socket';
    my $took = run_child(15 * TIMEOUT_MULT, sub {
        my $f = Feersum->new_instance();
        $f->use_socket($sock);
        $f->psgi_request_handler(sub {
            [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
        });
        my $kick = EV::timer 0.2 * TIMEOUT_MULT, 0, sub { $f->graceful_shutdown(sub { }) };
        EV::run();   # must return
    });
    ok defined $took,
        sprintf('EV::run returns after graceful_shutdown, so the loop is not '
              . 'pinned by a server that has stopped serving (%s)',
                defined $took ? sprintf('exited in %.1fs', $took) : 'had to be killed');
}

# --- 2: a connection busy at shutdown must not hold the drain for read_timeout
{
    my ($sock, $port) = get_listen_socket();
    # Deliberately far above the time the app needs, so waiting it out is
    # unmistakable: with the bug the drain lands near 20s, not near 1s.
    my $RD = 20 * TIMEOUT_MULT;

    my $client = fork();
    die "fork: $!" unless defined $client;
    if (!$client) {
        # Bounded on its own: when the server has to be killed rather than
        # exiting, this must still report instead of hanging the file.
        $SIG{ALRM} = sub { POSIX::_exit(4) };
        alarm $RD;
        select undef, undef, undef, 0.4 * TIMEOUT_MULT;
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                      Timeout => 10 * TIMEOUT_MULT);
        POSIX::_exit(2) unless $s;
        syswrite $s, "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n";
        my $raw = '';
        while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $raw .= $z }
        POSIX::_exit($raw =~ /drained/ ? 0 : 3);
    }

    my $took = run_child($RD * 0.75, sub {
        my $f = Feersum->new_instance();
        $f->use_socket($sock);
        $f->set_keepalive(1);
        $f->read_timeout($RD);
        my (@held, $kick);
        $f->psgi_request_handler(sub {
            my $env = shift;
            # Start the shutdown from the request, not from a wall-clock guess.
            # The condition under test is a connection BUSY when the shutdown
            # begins; timing it externally raced server startup on slow
            # runners, and a connection still sitting in the listen backlog
            # when graceful_shutdown closed the listeners was simply dropped.
            $kick ||= EV::timer 0.2 * TIMEOUT_MULT, 0,
                                sub { $f->graceful_shutdown(sub { }) };
            return sub {
                my $w = shift->([200, ['Content-Type' => 'text/plain']]);
                push @held, [$w, EV::timer(1.0 * TIMEOUT_MULT, 0,
                                           sub { $w->write('drained'); $w->close })];
            };
        });
        EV::run();
    });
    close $sock;

    ok defined $took, 'the drain finished rather than being killed';
    cmp_ok $took // $RD, '<', $RD / 2,
        sprintf('a connection that goes idle mid-drain is reaped instead of '
              . 'waiting out read_timeout=%ds (drain took %s)', $RD,
                defined $took ? sprintf('%.1fs', $took) : 'too long');

    my $creaped = 0;
    my $ct0 = Time::HiRes::time();
    while (Time::HiRes::time() - $ct0 < 10 * TIMEOUT_MULT) {
        if (waitpid($client, POSIX::WNOHANG) == $client) { $creaped = 1; last }
        select undef, undef, undef, 0.05;
    }
    if (!$creaped) { kill 'KILL', $client; waitpid $client, 0; $? = -1 << 8 }
    is $? >> 8, 0, 'the in-flight request still got its whole response';
}
