#!perl
# Test write_timeout: connections with stalled writes are closed
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More tests => 9;
use Test::Fatal;
use lib 't'; use Utils;
use IO::Socket::INET;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
is exception { $evh->use_socket($socket) }, undef, "bound to socket";

# Default is 0 (disabled)
is $evh->write_timeout, 0, "write_timeout defaults to 0";

# Set a short write timeout for testing
my $wt = 1.0 * TIMEOUT_MULT;
$evh->write_timeout($wt);
is $evh->write_timeout, $wt, "write_timeout set to $wt";

# Streaming response that produces lots of data via poll_cb
$evh->request_handler(sub {
    my $r = shift;
    my $w = $r->start_streaming(200, ["Content-Type" => "text/plain"]);
    $w->poll_cb(sub {
        my $writer = shift;
        # Keep producing data to fill kernel send buffer
        $writer->write("x" x 65536);
    });
});

my $cv = AE::cv;
$cv->begin;

# Use raw socket: connect, send request, then NEVER read.
# Set socket buffers as small as possible to trigger stalling faster.
my $raw = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die "connect: $!";
$raw->sockopt(SO_RCVBUF, 1);  # minimize recv buffer
$raw->syswrite("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");

# Wait long enough for: kernel buffers to fill + write_timeout to fire + margin
# Don't read from the socket at all - just wait, then check.
my $wait = ($wt + 5) * TIMEOUT_MULT;
my $t; $t = AE::timer($wait, 0, sub {
    undef $t;
    # Now check: the server should have closed the connection.
    # Try to read - if server closed, we get EOF (or data then EOF).
    $raw->blocking(0);
    my $buf;
    my $n = $raw->sysread($buf, 65536);
    if (defined($n) && $n == 0) {
        pass "connection was closed (write timeout fired) - EOF";
    }
    elsif (defined($n) && $n > 0) {
        # Got some data, try reading again for EOF
        my $n2 = $raw->sysread($buf, 65536);
        while (defined($n2) && $n2 > 0) {
            $n2 = $raw->sysread($buf, 65536);
        }
        if (defined($n2) && $n2 == 0) {
            pass "connection was closed (write timeout fired) - EOF after data";
        } else {
            fail "connection still open after timeout (got data but no EOF)";
        }
    }
    else {
        # EAGAIN or error
        if ($!{EAGAIN} || $!{EWOULDBLOCK}) {
            fail "connection still open after timeout (EAGAIN - server didn't close)";
        } else {
            pass "connection was closed (write timeout fired) - error: $!";
        }
    }
    close $raw;
    $cv->end;
});

$cv->recv;

# Test that write_timeout(0) disables it
$evh->write_timeout(0);
is $evh->write_timeout, 0, "write_timeout disabled";

# Test negative value croaks
like exception { $evh->write_timeout(-1) }, qr/non-negative/,
    "negative write_timeout croaks";
