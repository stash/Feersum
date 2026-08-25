#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 23;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

#######################################################################
# Test set_server_name_and_port() and unlisten()
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

#######################################################################
# Test 1: set_server_name_and_port() changes SERVER_NAME and SERVER_PORT
#######################################################################
{
    my %captured_env;

    $feer->psgi_request_handler(sub {
        my $env = shift;
        $captured_env{SERVER_NAME} = $env->{SERVER_NAME};
        $captured_env{SERVER_PORT} = $env->{SERVER_PORT};
        return [200, ['Content-Type' => 'text/plain'], ['OK']];
    });

    # First request - should have default values (127.0.0.1 from socket, $port)
    {
        my $cv = AE::cv;
        my $h = simple_client GET => '/test1', sub {
            my ($body, $hdr) = @_;
            $cv->send;
        };
        $cv->recv;

        # Default comes from socket's getsockname - typically 127.0.0.1 or localhost
        like $captured_env{SERVER_NAME}, qr/^(?:localhost|127\.0\.0\.1)$/, 'default SERVER_NAME is localhost or 127.0.0.1';
        is $captured_env{SERVER_PORT}, $port, "default SERVER_PORT is $port";
    }

    # Override with custom values
    $feer->set_server_name_and_port('api.example.com', 8080);

    # Second request - should have overridden values
    {
        my $cv = AE::cv;
        my $h = simple_client GET => '/test2', sub {
            my ($body, $hdr) = @_;
            $cv->send;
        };
        $cv->recv;

        is $captured_env{SERVER_NAME}, 'api.example.com', 'SERVER_NAME overridden';
        is $captured_env{SERVER_PORT}, 8080, 'SERVER_PORT overridden';
    }

    # Override again with different values
    $feer->set_server_name_and_port('backend.internal', 3000);

    {
        my $cv = AE::cv;
        my $h = simple_client GET => '/test3', sub {
            my ($body, $hdr) = @_;
            $cv->send;
        };
        $cv->recv;

        is $captured_env{SERVER_NAME}, 'backend.internal', 'SERVER_NAME changed again';
        is $captured_env{SERVER_PORT}, 3000, 'SERVER_PORT changed again';
    }
}

#######################################################################
# Test 2: unlisten() stops accepting new connections
#######################################################################
{
    # Set simple handler
    $feer->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
    });

    # Verify server is working before unlisten
    {
        my $cv = AE::cv;
        my $response_ok = 0;
        my $h = simple_client GET => '/before-unlisten', sub {
            my ($body, $hdr) = @_;
            $response_ok = 1 if $hdr->{Status} == 200;
            $cv->send;
        };
        $cv->recv;
        ok $response_ok, 'server responds before unlisten';
    }

    # Call unlisten
    $feer->unlisten();
    pass 'unlisten() called successfully';

    # After unlisten, the socket may still accept TCP connections at kernel level
    # (listen backlog) but Feersum won't process new requests.
    # We verify unlisten worked by checking that requests timeout/fail.
    {
        my $cv = AE::cv;
        my $got_response = 0;
        my $got_error = 0;

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub {
                $got_error = 1;
                $cv->send;
            },
            on_connect => sub {
                $_[0]->push_write("GET /after-unlisten HTTP/1.1\r\nHost: localhost\r\n\r\n");
                $_[0]->push_read(line => "\r\n", sub {
                    $got_response = 1;
                    $cv->send;
                });
            },
        );

        # Short timeout - if unlisten worked, we won't get a response
        my $timeout = AE::timer 0.5, 0, sub { $cv->send };
        $cv->recv;

        ok !$got_response, 'no response after unlisten (request not processed)';
    }

    # Double unlisten should be safe (not crash)
    eval { $feer->unlisten() };
    ok !$@, 'double unlisten() does not crash';
}

#######################################################################
# Test 3: Can use_socket() again after unlisten()
#######################################################################
{
    my ($socket2, $port2) = get_listen_socket();
    ok $socket2, 'got second listen socket';

    $feer->use_socket($socket2);
    pass 'use_socket() after unlisten() succeeds';

    # Verify server works on new socket
    {
        my $cv = AE::cv;
        my $response_ok = 0;

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port2],
            on_error => sub { $cv->send },
            on_connect => sub {
                $_[0]->push_write("GET /new-socket HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
                $_[0]->push_read(line => "\r\n", sub {
                    $response_ok = 1 if $_[1] =~ /200 OK/;
                    $_[0]->on_read(sub {});
                    $_[0]->on_eof(sub { $cv->send });
                });
            },
        );

        my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;

        ok $response_ok, 'server responds on new socket after re-listen';
    }

    # Clean up
    $feer->unlisten();
}

#######################################################################
# Test 4: graceful_shutdown with zero active conns calls callback immediately
#######################################################################
{
    my ($socket3, $port3) = get_listen_socket();
    my $feer2 = Feersum->new_instance();
    $feer2->use_socket($socket3);
    $feer2->request_handler(sub {
        $_[0]->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
    });

    my $called = 0;
    $feer2->graceful_shutdown(sub { $called = 1 });
    is $called, 1, 'graceful_shutdown callback fires immediately with zero active conns';
}

#######################################################################
# Test 5: graceful_shutdown callback that dies doesn't crash server
#######################################################################
{
    my ($socket4, $port4) = get_listen_socket();
    my $feer3 = Feersum->new_instance();
    $feer3->use_socket($socket4);
    $feer3->request_handler(sub {
        $_[0]->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
    });

    # XS uses G_EVAL to catch the die; server should survive.
    # Note: ENTER/LEAVE scope in XS restores $@ so the error won't
    # be visible to the caller, but the server must not crash.
    $feer3->graceful_shutdown(sub { die "intentional test error\n" });
    pass 'server survived dying graceful_shutdown callback';
}

#######################################################################
# Test 6: graceful_shutdown double-call croaks
#######################################################################
{
    my ($socket5, $port5) = get_listen_socket();
    my $feer4 = Feersum->new_instance();
    $feer4->use_socket($socket5);
    $feer4->request_handler(sub {
        $_[0]->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
    });

    $feer4->graceful_shutdown(sub {});
    eval { $feer4->graceful_shutdown(sub {}) };
    like $@, qr/already shutting down/, 'double graceful_shutdown croaks';
}

pass 'all server control tests completed';
