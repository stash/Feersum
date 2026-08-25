#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 14;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

#######################################################################
# Test max_connections limit to prevent connection exhaustion DoS
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

# Test getter/setter
{
    is $feer->max_connections, 10000, 'max_connections default is 10000 (protection enabled)';
    $feer->max_connections(5);
    is $feer->max_connections, 5, 'max_connections set to 5';
}

# Set up a handler that keeps connections open until we release them
my @pending_responses;
$feer->request_handler(sub {
    my $r = shift;
    # Store the connection to keep it open
    push @pending_responses, $r;
});

# Test that connections are rejected when limit is reached
{
    $feer->max_connections(3);
    is $feer->max_connections, 3, 'max_connections set to 3 for test';

    @pending_responses = ();

    # Open 3 connections that will be held open
    my @handles;
    for my $i (1..3) {
        my $cv = AE::cv;
        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send },
            on_connect => sub {
                $_[0]->push_write("GET /$i HTTP/1.1\r\nHost: localhost\r\n\r\n");
                $cv->send;
            },
        );
        push @handles, $h;
        my $timeout = AE::timer 1 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;
    }

    # Wait for requests to be received
    my $wait_cv = AE::cv;
    my $wait = AE::timer 0.2 * TIMEOUT_MULT, 0, sub { $wait_cv->send };
    $wait_cv->recv;

    is scalar(@pending_responses), 3, '3 requests received and held';
    is $feer->active_conns, 3, 'active_conns is 3';

    # Now try to connect - should fail or be rejected
    my $fourth_connected = 0;
    my $fourth_response  = '';
    my $cv = AE::cv;
    my $t4;
    my $h4 = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },  # Expected: connection reset
        on_connect => sub {
            $fourth_connected = 1;
            $_[0]->push_write("GET /4 HTTP/1.1\r\nHost: localhost\r\n\r\n");
            $_[0]->on_read(sub { $fourth_response .= $_[0]->rbuf; $_[0]->rbuf = '' });
            # If we connected, wait briefly to see if we get a response
            $t4 = AE::timer 0.3, 0, sub { $cv->send };
        },
    );
    my $timeout = AE::timer 1 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    # Either the 4th connection failed, or it connected but got no response
    # (because max_connections prevents new requests from being processed)
    ok $feer->active_conns <= 3, "active_conns still <= 3 after 4th attempt";

    # $fourth_connected and the response were previously captured and dropped,
    # so what an over-limit client actually observes was pinned nowhere.  The
    # kernel completes the TCP handshake from the listen backlog whether or not
    # Feersum accepts, so connecting is expected; being *served* is not.
    is scalar(@pending_responses), 3,
        'over-limit request was not dispatched to the handler';
    is $fourth_response, '',
        'over-limit client got no response while the limit was saturated';

    # Clean up - send responses to release connections
    for my $r (@pending_responses) {
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
    }
    @pending_responses = ();

    # Destroy handles
    $_->destroy for @handles;
    $h4->destroy if $h4;
}

# Switch to simple handler for remaining tests
$feer->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
});

# Test that after connections close, new ones can be accepted
{
    # Wait for connections to fully close
    my $cv = AE::cv;
    my $timer = AE::timer 0.5 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    # Now we should be able to connect again
    $cv = AE::cv;
    my $response_received = 0;

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
        on_connect => sub {
            $_[0]->push_write("GET /after HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            $_[0]->push_read(line => "\r\n", sub {
                $response_received = 1 if $_[1] =~ /200 OK/;
                $_[0]->on_read(sub {});
                $_[0]->on_eof(sub { $cv->send });
            });
        },
    );

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok $response_received, 'new connection accepted after previous ones closed';
}

# Test that setting to 0 disables the limit
{
    $feer->max_connections(0);
    is $feer->max_connections, 0, 'max_connections set back to 0';

    my $cv = AE::cv;
    my $response_received = 0;

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
        on_connect => sub {
            $_[0]->push_write("GET /unlimited HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            $_[0]->push_read(line => "\r\n", sub {
                $response_received = 1 if $_[1] =~ /200 OK/;
                $_[0]->on_read(sub {});
                $_[0]->on_eof(sub { $cv->send });
            });
        },
    );

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok $response_received, 'connections work with limit disabled';
}

pass 'all max_connections tests completed';
