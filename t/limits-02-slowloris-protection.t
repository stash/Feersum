#!/usr/bin/env perl
# Test Slowloris protection via header_timeout
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

$feer->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
});

###############################################################################
# Test 1: header_timeout getter/setter
###############################################################################
{
    is $feer->header_timeout(), 10, 'default header_timeout is 10 (enabled)';

    $feer->header_timeout(30);
    is $feer->header_timeout(), 30, 'header_timeout can be set to 30';

    $feer->header_timeout(0);
    is $feer->header_timeout(), 0, 'header_timeout can be disabled (0)';

    eval { $feer->header_timeout(-1) };
    like $@, qr/non-negative/, 'header_timeout(-1) croaks';
}

###############################################################################
# Test 2: Normal request completes when header_timeout is set
###############################################################################
{
    $feer->header_timeout(5);  # 5 second deadline

    my $cv = AE::cv;
    my $h = simple_client GET => '/normal', sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, 'normal request succeeds with header_timeout';
        $cv->send;
    };
    $cv->recv;
}

###############################################################################
# Test 3: Slow headers trigger 408 when header_timeout is exceeded
###############################################################################
{
    $feer->header_timeout(1);  # 1 second deadline (short for testing)

    my $cv = AE::cv;

    # Connect but send headers very slowly
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or die "Connect failed: $!";

    # Send partial headers
    print $sock "GET /slow HTTP/1.1\r\n";
    $sock->flush;

    # Wait for header_timeout to trigger (1 second + margin)
    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    # Try to read response - should be 408 or connection closed
    $sock->blocking(0);
    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    # Should get 408 Request Timeout (Slowloris protection)
    like $response, qr/408|Header timeout|Slowloris/i,
        'slow headers trigger 408 response (Slowloris protection)';
}

###############################################################################
# Test 4: Fast request succeeds even with short header_timeout
###############################################################################
{
    # Must scale: on a loaded smoker a fast request can legitimately take
    # longer than a flat 2s, and the server would correctly 408 it.
    $feer->header_timeout(2 * TIMEOUT_MULT);

    my $cv = AE::cv;
    my $h = simple_client GET => '/fast', sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, 'fast request succeeds with short header_timeout';
        $cv->send;
    };
    $cv->recv;
}

###############################################################################
# Test 5: Disable header_timeout - slow request should use read_timeout instead
###############################################################################
{
    $feer->header_timeout(0);  # disabled
    $feer->read_timeout(1);    # 1 second read timeout

    my $cv = AE::cv;

    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 5,
    ) or die "Connect failed: $!";

    # Send partial headers
    print $sock "GET /slow2 HTTP/1.1\r\n";
    $sock->flush;

    # Wait for read_timeout
    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    $sock->blocking(0);
    my $response = '';
    while (my $line = <$sock>) {
        $response .= $line;
    }
    close $sock;

    # Should still get 408 from read_timeout
    like $response, qr/408|too long/i,
        'with header_timeout=0, read_timeout still protects';

    # Reset
    $feer->read_timeout(5);
}

###############################################################################
# Test 6: Server still works after Slowloris attempt
###############################################################################
{
    $feer->header_timeout(2 * TIMEOUT_MULT);

    my $cv = AE::cv;
    my $h = simple_client GET => '/after-attack', sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, 'server works after Slowloris attempt';
        is $body, 'OK', 'got correct response body';
        $cv->send;
    };
    $cv->recv;
}

done_testing;
