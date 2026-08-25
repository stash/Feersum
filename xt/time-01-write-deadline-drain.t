#!perl
# write_timeout reaps a client that stops reading a complete response (the
# RESPOND_SHUTDOWN state included) but not a transfer that is still
# progressing.  Author-only: needs many seconds of steady draining.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp ();
use Socket ();
use IO::Socket::INET ();
use EV;

plan tests => 5;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
$feer->write_timeout(2 * TMULT);
# Raised so that only write_timeout can plausibly close the stalled connection
# below (read_timeout doubles as the keepalive idle timeout and defaults to 5s).
$feer->read_timeout(30 * TMULT);

# Must comfortably exceed the kernel send+receive buffers, otherwise the whole
# response lands in the socket buffer, the drain completes, and there is
# nothing for the write timer to reap.
my $big = 'x' x (16 * 1024 * 1024);
our $SENDFILE_PATH;

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '/';
    if ($p eq q{/sendfile} && $SENDFILE_PATH) {
        return sub {
            my $respond = shift;
            my $w = $respond->([200, [q{Content-Type} => q{application/octet-stream}]]);
            open my $in, q{<}, $SENDFILE_PATH or die "open: $!";
            $w->sendfile($in);
        };
    }
    return [200, ['Content-Type' => 'text/plain'], [$big]] if $p eq '/big';
    return [200, ['Content-Type' => 'text/plain'], ['BODY-FOR-200']];
});

#####################################################################
# 2. write_timeout must reap a client that stops reading a complete response.
#####################################################################
# Asserted server-side: a client-side EOF is not a reliable signal once the
# peer stops reading (the FIN sits behind megabytes of unread data).  The
# bound is generous: the drain probe costs an extra round on the BSDs.
{
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        select undef, undef, undef, 0.3 * TMULT;
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        );
        if ($s) {
            setsockopt($s, Socket::SOL_SOCKET(), Socket::SO_RCVBUF(), pack("I", 4096));
            # Connection: close keeps the keepalive idle timer out of it, and
            # read_timeout is raised above, so only write_timeout can reap.
            $s->print("GET /big HTTP/1.1\015\012Host: l\015\012".
                      "Connection: close\015\012\015\012");
            $s->flush;
            select undef, undef, undef, 28 * TMULT;   # never read a byte
        }
        exit 0;
    }

    my ($saw_conn, $reaped, $elapsed) = (0, 0, 0);
    my $w = EV::timer 0.5, 0.5, sub {
        $elapsed += 0.5;
        my $n = $feer->active_conns;
        $saw_conn = 1 if $n > 0;
        if ($saw_conn && $n == 0) { $reaped = 1; EV::break(EV::BREAK_ALL()); return }
        EV::break(EV::BREAK_ALL()) if $elapsed >= 25 * TMULT;
    };
    EV::run;
    kill 'KILL', $pid;
    waitpid($pid, 0);

    ok $saw_conn, "stalled reader connected";
    ok $reaped, "write_timeout reaped a stalled reader of a complete response"
        or diag sprintf
            "gave up after %.1fs with %d conn(s) still open; write_timeout=%s "
            . "read_timeout=%s os=%s.  The deadline never fired, or fired and "
            . "the connection outlived it.",
            $elapsed, $feer->active_conns, $feer->write_timeout,
            $feer->read_timeout, $^O;
}

#####################################################################
# 2b. ...but a transfer that is still progressing must not be reaped: a
#     sendfile() response sits in RESPOND_SHUTDOWN for its whole duration
#     and must reset the write deadline on every successful send.
#####################################################################
SKIP: {
    skip "sendfile is Linux-only", 2 unless $^O eq 'linux';
    my ($tfh, $tpath) = File::Temp::tempfile(UNLINK => 1);
    my $size = 4 * 1024 * 1024;
    print {$tfh} ('S' x $size);
    close $tfh;
    $SENDFILE_PATH = $tpath;

    run_client("sendfile-progress-not-reaped", sub {
        # SO_RCVBUF must be set BEFORE connect.  Setting it afterwards leaves
        # the already-negotiated window in place and the transfer wedges - that
        # is a client artifact (it reproduces against a plain non-Feersum
        # socket server too), not a server bug, but it will silently ruin this
        # test if the socket is built with IO::Socket::INET->new(PeerAddr=>...).
        socket(my $s, Socket::AF_INET(), Socket::SOCK_STREAM(), 0) or return 10;
        setsockopt($s, Socket::SOL_SOCKET(), Socket::SO_RCVBUF(), pack("I", 8192))
            or return 11;
        connect($s, Socket::pack_sockaddr_in($port, Socket::inet_aton('127.0.0.1')))
            or return 12;

        syswrite($s, "GET /sendfile HTTP/1.0\015\012\015\012") or return 13;
        # Small paced reads keep the server genuinely blocked on writability
        # for far longer than the 2s write_timeout set above.
        my $got = 0;
        while (1) {
            my $n = sysread($s, my $buf, 4096);
            last if !defined $n || $n == 0;
            $got += $n;
            select undef, undef, undef, 0.005;
        }
        # Headers + the whole file.  Pre-fix this stopped a few hundred KB short.
        return 14 unless $got > $size;
        return 0;
    });
}

