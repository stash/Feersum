#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 7;
use lib 't'; use Utils;
use IO::Socket::INET;
use IO::Select;

BEGIN { use_ok('Feersum') };

my $CRLF = "\015\012";

#######################################################################
# Test: After return_from_io(), header_timeout is re-activated so
# Slowloris attacks on the next request are still detected.
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->header_timeout(1);  # 1 second header timeout

my $request_count = 0;
my @kept_ios;

$feer->request_handler(sub {
    my $req = shift;
    $request_count++;

    if ($request_count == 1) {
        # First request: take io, then return control for keepalive
        my $io = $req->io;
        my $cnt = $req->return_from_io($io);

        # Send manual response via the io handle
        $io->autoflush(1);
        print $io "HTTP/1.1 200 OK${CRLF}Content-Type: text/plain${CRLF}Content-Length: 2${CRLF}Connection: keep-alive${CRLF}${CRLF}OK";
        push @kept_ios, $io;
    }
    elsif ($request_count == 2) {
        # This should NOT be reached if Slowloris protection works
        $req->send_response(200, ['Content-Type' => 'text/plain'], 'BAD');
    }
});

# Use raw IO::Socket for precise control - no AnyEvent buffering
my $client = IO::Socket::INET->new(
    PeerAddr => 'localhost',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 3,
) or die "connect failed: $!";

$client->autoflush(1);

# First request - completes normally
print $client "GET / HTTP/1.1${CRLF}Host: localhost${CRLF}Connection: keep-alive${CRLF}${CRLF}";

# Read first response (need event loop to process)
{
    my $cv = AE::cv;
    my $timer = AE::timer 0.5 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
}

my $resp = '';
$client->blocking(0);
while (my $n = sysread($client, my $buf, 4096)) {
    $resp .= $buf;
}
$client->blocking(1);

like $resp, qr/200 OK/, 'first request completed';

# Now simulate Slowloris: send partial headers, then stall
print $client "GET / HTTP/1.1${CRLF}Host: ";

# Wait for header_timeout to fire (1s) + margin.
# The event loop must run so libev can fire the timer.
{
    my $cv = AE::cv;
    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
}

# Check if the connection was closed by the server
my $sel = IO::Select->new($client);
my $closed = 0;
if ($sel->can_read(0.1)) {
    my $n = sysread($client, my $buf, 4096);
    if (!defined($n) || $n == 0) {
        $closed = 1;
    } else {
        # Got a 408 response - that's also header_timeout working
        $closed = 1 if $buf =~ /408|close/i;
    }
} else {
    # No data available and not closed - timeout didn't fire
    $closed = 0;
}

ok $closed, 'header_timeout closed connection after return_from_io (Slowloris blocked)';
is $request_count, 1, 'second request was NOT served';

close($client);

# Verify server is still alive and serving new connections
$feer->header_timeout(10);  # generous timeout
$request_count = 0;
@kept_ios = ();

$feer->request_handler(sub {
    my $req = shift;
    $request_count++;
    $req->send_response(200, ['Content-Type' => 'text/plain'], 'ALIVE');
});

my $cv = AE::cv;
my $resp2 = '';
my $h2 = AnyEvent::Handle->new(
    # 127.0.0.1, not 'localhost': the listener is an IO::Socket::INET, which is
    # AF_INET-only and so always binds the IPv4 address, while AnyEvent resolves
    # dual-stack and may try ::1 first.  The IO::Socket::INET client above has
    # no such ambiguity, which is why only this half of the test fails.
    connect => ['127.0.0.1', $port],
    on_error => sub { $cv->send },
    on_eof   => sub { $cv->send },
);
$h2->push_write("GET / HTTP/1.1${CRLF}Host: localhost${CRLF}Connection: close${CRLF}${CRLF}");
$h2->on_read(sub {
    $resp2 .= $_[0]->rbuf;
    $_[0]->rbuf = '';
});
my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send };
$cv->recv;

like $resp2, qr/200 OK/, 'server still alive after timeout enforcement';
like $resp2, qr/ALIVE/, 'new connection served normally';
