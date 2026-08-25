#!/usr/bin/env perl
# Under max_connections pressure a new connection evicts the oldest idle
# keepalive connection and is served rather than refused.
use strict;
use warnings;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 10;
use lib 't'; use Utils;
use IO::Socket::INET;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
$feer->max_connections(2);

my $request_count = 0;
$feer->request_handler(sub {
    my $r = shift;
    $request_count++;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"ok $request_count");
});

is $feer->max_connections, 2, 'max_connections applied';

# Helper: send a request on a given socket, read the full response, return body
sub do_request {
    my ($sock, $label) = @_;
    $sock->print("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

    # Pump event loop to process the request
    for (1..20) {
        EV::run(EV::RUN_NOWAIT());
        select(undef, undef, undef, 0.02 * TIMEOUT_MULT);
    }

    $sock->blocking(0);
    my $resp = '';
    while (defined(my $n = sysread($sock, my $buf, 8192))) {
        last if $n == 0;
        $resp .= $buf;
    }
    $sock->blocking(1);

    if ($resp =~ /^HTTP\/1\.1 200/m && $resp =~ /\r\n\r\n(.+)$/s) {
        return $1;
    }
    return undef;
}

# Step 1: Open conn1, send request, leave in keepalive-idle
my $conn1 = IO::Socket::INET->new(
    PeerAddr => "127.0.0.1:$port",
    Timeout  => 3 * TIMEOUT_MULT,
);
ok $conn1, "conn1 connected";
my $body1 = do_request($conn1, "conn1");
like $body1, qr/^ok \d+$/, "conn1 got valid response: $body1";

# Step 2: Open conn2, send request, leave in keepalive-idle
my $conn2 = IO::Socket::INET->new(
    PeerAddr => "127.0.0.1:$port",
    Timeout  => 3 * TIMEOUT_MULT,
);
ok $conn2, "conn2 connected";
my $body2 = do_request($conn2, "conn2");
like $body2, qr/^ok \d+$/, "conn2 got valid response: $body2";

# Now both connections are idle-keepalive, active_conns=2, max_connections=2.
# Step 3: Open conn3 - this should trigger eviction of an idle conn.
my $conn3 = IO::Socket::INET->new(
    PeerAddr => "127.0.0.1:$port",
    Timeout  => 3 * TIMEOUT_MULT,
);

# If eviction works, conn3 connects and gets a response.
# If eviction is broken, accept is paused and conn3 times out.
# A failed conn3 IS the failure mode (accept paused because eviction did not
# free a slot), so it must fail rather than skip.
ok $conn3, "conn3 connected (eviction made room)";
SKIP: {
    skip "conn3 did not connect", 1 unless $conn3;

    my $body3 = do_request($conn3, "conn3");
    like $body3, qr/^ok \d+$/, "conn3 got valid response after eviction: $body3";
}

# Step 4: Verify one of conn1/conn2 was evicted (closed server-side).
# MRU eviction: conn1 was inserted first (head), so it's evicted first.
# A read on the evicted socket returns EOF (0 bytes).
{
    my $evicted = 0;
    for my $c ($conn1, $conn2) {
        $c->blocking(0);
        my $n = sysread($c, my $buf, 1);
        # EOF (n=0) or error (n=undef, not EAGAIN) means server closed it
        if (!defined($n) ? !$!{EAGAIN} : $n == 0) {
            $evicted++;
        }
    }
    ok $evicted >= 1, "at least one idle conn was evicted (got $evicted)";
}

# Cleanup
$conn1->close if $conn1;
$conn2->close if $conn2;
$conn3->close if $conn3;
