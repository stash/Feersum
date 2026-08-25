#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 23;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

# Suppress expected "DIED:" messages during error path testing
# These are intentional exceptions to verify server recovery
{
    no warnings 'redefine';
    *Feersum::DIED = sub { }; # silent during tests
}

# Helper to temporarily suppress STDERR for expected warnings from C code
sub with_stderr_suppressed (&) {
    my $code = shift;
    open my $stderr_save, '>&', \*STDERR or die "Can't dup STDERR: $!";
    open STDERR, '>', '/dev/null' or die "Can't redirect STDERR: $!";
    my @result = eval { $code->() };
    my $err = $@;
    open STDERR, '>&', $stderr_save or die "Can't restore STDERR: $!";
    die $err if $err;
    return wantarray ? @result : $result[0];
}

#######################################################################
# Test error paths: calling methods outside request context,
# exception during streaming, etc.
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

#######################################################################
# Test 1: Request accessor methods outside handler context should croak
#######################################################################
{
    # Create a connection object outside of request handler
    # by capturing it during a request
    my $captured_conn;

    $feer->request_handler(sub {
        my $r = shift;
        $captured_conn = $r;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
    });

    # Make a request to capture connection
    {
        my $cv = AE::cv;
        my $h = simple_client GET => '/capture', sub { $cv->send };
        $cv->recv;
    }

    # Now try to call methods on the captured connection outside handler
    # These should croak because the request is no longer active

    # Note: Some methods may still work on a completed connection,
    # but request-specific data accessors should fail or return undef

    # Test that the connection object exists
    ok defined($captured_conn), 'captured connection object';

    # After response is sent, calling send_response again should fail
    eval { $captured_conn->send_response(200, [], 'again') };
    ok $@, 'send_response after completion croaks';
    like $@, qr/already|complete|sent|closed/i, 'error mentions completion';
}

#######################################################################
# Test 2: Exception in request handler - server should survive
#######################################################################
{
    my $exception_thrown = 0;

    $feer->request_handler(sub {
        my $r = shift;
        $exception_thrown = 1;
        die "Intentional test exception";
    });

    # Make request that triggers exception
    {
        my $cv = AE::cv;
        my $got_response = 0;

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send },
            on_connect => sub {
                $_[0]->push_write("GET /die HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
                $_[0]->push_read(line => "\r\n", sub {
                    $got_response = 1 if $_[1] =~ /500/;
                    $_[0]->on_read(sub {});
                    $_[0]->on_eof(sub { $cv->send });
                });
            },
        );

        my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;

        ok $exception_thrown, 'exception was thrown in handler';
        ok $got_response, 'server returned 500 after exception';
    }

    # Verify server still works after exception
    $feer->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'recovered');
    });

    {
        my $cv = AE::cv;
        my $response_ok = 0;

        my $h = simple_client GET => '/after-exception', sub {
            my ($body, $hdr) = @_;
            $response_ok = 1 if $hdr->{Status} == 200 && $body eq 'recovered';
            $cv->send;
        };
        $cv->recv;

        ok $response_ok, 'server works after exception in handler';
    }
}

#######################################################################
# Test 3: Exception during streaming response
# (wrapped to suppress expected C-level warning about already responding)
#######################################################################
{
    my $streaming_started = 0;
    my $exception_in_stream = 0;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $streaming_started = 1;
        $w->write("first chunk");
        $exception_in_stream = 1;
        die "Exception during streaming";
        # This should not be reached
        $w->write("second chunk");
        $w->close();
    });

    with_stderr_suppressed {
        my $cv = AE::cv;
        my $got_first_chunk = 0;
        my $response_data = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send },
            on_eof => sub { $cv->send },
            on_connect => sub {
                $_[0]->push_write("GET /stream-die HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
                $_[0]->on_read(sub {
                    $response_data .= $_[0]->rbuf;
                    $_[0]->rbuf = '';
                    $got_first_chunk = 1 if $response_data =~ /first chunk/;
                });
            },
        );

        my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;

        ok $streaming_started, 'streaming was started';
        ok $exception_in_stream, 'exception was triggered during streaming';
        # $got_first_chunk was previously dead: assert that the data written
        # BEFORE the exception actually reached the client, and that the
        # connection was then closed rather than left hanging.
        ok $got_first_chunk, 'pre-exception chunk reached the client';
        like $response_data, qr{^HTTP/1\.[01] 200},
            'server sent response headers before the exception';
    };

    # Verify server still works
    $feer->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
    });

    {
        my $cv = AE::cv;
        my $response_ok = 0;
        my $h = simple_client GET => '/after-stream-die', sub {
            my ($body, $hdr) = @_;
            $response_ok = 1 if $hdr->{Status} == 200;
            $cv->send;
        };
        $cv->recv;

        ok $response_ok, 'server works after streaming exception';
    }
}

#######################################################################
# Test 4: Double close on writer - should not crash server
#######################################################################
{
    my $handler_completed = 0;
    my $first_close_ok = 0;
    my $second_close_result = '';

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("data");
        eval { $w->close(); $first_close_ok = 1; };
        # The assignment has to happen AFTER the eval: inside it, a croak from
        # close() aborts before the assignment, so 'croaked' was unreachable.
        eval { $w->close(); 1 };
        $second_close_result = $@ ? 'croaked' : 'ok';
        $handler_completed = 1;
    });

    {
        my $cv = AE::cv;
        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send },
            on_eof => sub { $cv->send },
            on_connect => sub {
                $_[0]->push_write("GET /double-close HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
                $_[0]->on_read(sub {});
            },
        );
        my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;
    }

    # The key assertion: handler completed without crashing
    ok $handler_completed, 'double close on writer handled (handler completed)';
    ok $first_close_ok, 'first close() succeeded';
    # Verified behaviour: the second close croaks
    # "Operation not allowed: Handle is closed." - it is rejected, not ignored.
    is $second_close_result, 'croaked', 'second close() is rejected, not silent';
}

#######################################################################
# Test 5: Write after close
#######################################################################
{
    my $write_after_close_handled = 0;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("data");
        $w->close();
        eval { $w->write("more data") };
        $write_after_close_handled = 1 if $@;  # Should croak
    });

    {
        my $cv = AE::cv;
        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send },
            on_eof => sub { $cv->send },
            on_connect => sub {
                $_[0]->push_write("GET /write-after-close HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
                $_[0]->on_read(sub {});
            },
        );
        my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;
    }

    ok $write_after_close_handled, 'write after close is rejected';
}

#######################################################################
# env() croaks like every other request accessor once the request is freed
# (return_from_io() frees it while the Connection object is still alive).
#######################################################################
{
    my ($sock, $port) = get_listen_socket();
    my $evh = Feersum->new_instance();
    $evh->use_socket($sock);

    my ($method_err, $env_err, $env_ret);
    $evh->request_handler(sub {
        my $r = shift;
        my $io = $r->io;
        $r->return_from_io($io);        # frees the request, NULLs c->req
        $method_err = defined(eval { $r->method }) ? undef : $@;
        $env_ret    = eval { $r->env };
        $env_err    = $@;
    });

    my $cv = AE::cv;
    my $h = AnyEvent::Handle->new(
        connect  => ['localhost', $port],
        on_error => sub { $cv->send },
        on_eof   => sub { $cv->send },
        on_connect => sub {
            $_[0]->push_write("GET /freed HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            $_[0]->on_read(sub {});
        },
    );
    my $timeout = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    like $method_err, qr/no active request/,
        'method() croaks once the request is freed';
    ok !defined($env_ret), 'env() returns nothing once the request is freed';
    like $env_err, qr/no active request/,
        'env() croaks instead of dereferencing a NULL request';
}
