#!/usr/bin/env perl
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 15;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;
use IO::Socket::INET;

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

my $request_count = 0;
$feer->request_handler(sub {
    my $r = shift;
    $request_count++;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"OK $request_count");
});

# Helper to make a quick request
sub make_request {
    my ($timeout) = @_;
    $timeout ||= 3 * TIMEOUT_MULT;

    my $cv = AE::cv;
    my $response = '';
    my $connected = 0;

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_connect => sub { $connected = 1; },
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
        timeout => $timeout,
    );

    $h->push_write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    $h->on_read(sub {
        $response .= $h->rbuf;
        $h->rbuf = '';
    });

    my $timer = AE::timer $timeout, 0, sub { $cv->send; };
    $cv->recv;

    return ($connected, $response);
}

#######################################################################
# Test: Initial state - not paused
#######################################################################

ok !$feer->accept_is_paused(), 'initially not paused';

#######################################################################
# Test: Normal request works
#######################################################################

{
    my ($connected, $response) = make_request();
    ok $connected, 'connected successfully';
    like $response, qr/200 OK/, 'got 200 response';
    like $response, qr/OK 1/, 'request handled';
}

#######################################################################
# Test: Pause accept
#######################################################################

ok $feer->pause_accept(), 'pause_accept returns true';
ok $feer->accept_is_paused(), 'accept_is_paused returns true';

# Double pause should return false
ok !$feer->pause_accept(), 'double pause returns false';

#######################################################################
# Test: New connections fail while paused
#######################################################################

{
    my $cv = AE::cv;

    # Try to connect - should fail or timeout
    my $sock = IO::Socket::INET->new(
        PeerAddr => 'localhost',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );

    # Connection might succeed (kernel backlog) but request won't be processed
    # Or connection might fail entirely
    if ($sock) {
        # Socket connected but server won't accept/process
        print $sock "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

        # Give a short time for response (shouldn't come)
        my $timer = AE::timer 0.5, 0, sub { $cv->send; };
        $cv->recv;

        # Check if we got any response
        $sock->blocking(0);
        my $buf;
        my $bytes = $sock->sysread($buf, 1024);

        # Should get nothing or incomplete response since server paused
        ok(!defined($bytes) || $bytes == 0 || $buf !~ /200 OK/,
           'no response while paused (connection may be in backlog)');
        close($sock);
    } else {
        pass 'connection refused/timeout while paused';
    }
}

#######################################################################
# Test: Resume accept
#######################################################################

ok $feer->resume_accept(), 'resume_accept returns true';
ok !$feer->accept_is_paused(), 'accept_is_paused returns false after resume';

# Double resume should return false
ok !$feer->resume_accept(), 'double resume returns false';

#######################################################################
# Test: Requests work after resume
#######################################################################

{
    my ($connected, $response) = make_request();
    ok $connected, 'connected after resume';
    like $response, qr/200 OK/, 'got 200 response after resume';
    # qr/OK/ alone is satisfied by the "200 OK" status line; check the body.
    like $response, qr/\r\n\r\n.*OK/s, 'request body delivered after resume';
}
