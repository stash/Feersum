#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use warnings;
use Test::More tests => 19;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my $CRLF = "\015\012";

#######################################################################
# PART 1: Test io() for protocol upgrade scenario
#######################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'upgrade: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);

    my $cv = AE::cv;
    my $got_io;
    my $upgrade_data;
    my $double_call_error;

    $feer->request_handler(sub {
        my $req = shift;

        # Test that we can get fileno
        my $fd = $req->fileno;
        ok defined($fd) && $fd >= 0, "upgrade: fileno returns valid fd ($fd)";

        # Test io() method - this takes over the socket
        my $io = $req->io;
        ok defined($io), 'upgrade: io() returns defined value';
        isa_ok $io, 'IO::Socket', 'upgrade: io() returns IO::Socket';

        # Verify we can get the fileno from the socket
        my $io_fd = fileno($io);
        is $io_fd, $fd, 'upgrade: IO socket has same fd as fileno()';

        # Test that calling io() twice throws an error
        eval { my $io2 = $req->io; };
        $double_call_error = $@;

        # For protocol upgrades, we send our own response
        my $response = "HTTP/1.1 101 Switching Protocols${CRLF}Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}";
        syswrite($io, $response);

        # Now read upgrade data from client
        my $h = AnyEvent::Handle->new(
            fh => $io,
            on_error => sub { $cv->croak("server error: $_[2]") },
        );

        $h->push_read(line => sub {
            $upgrade_data = $_[1];
            # Echo back
            $h->push_write("echo: $upgrade_data\n");
            # Give time for write to complete
            my $t; $t = AE::timer 0.1, 0, sub {
                undef $t;
                $h->destroy;
                $cv->send;
            };
        });

        $got_io = 1;
    });

    # Client: send upgrade request then additional data
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->croak("client error: $_[2]") },
    );

    my $request = "GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}";
    $h->push_write($request);

    my $got_upgrade = 0;
    my $echo_response = '';

    $h->push_read(regex => qr/\r\n\r\n/, sub {
        my $headers = $_[1];
        if ($headers =~ /101 Switching/) {
            $got_upgrade = 1;
            $h->push_write("hello from client\n");
            $h->push_read(line => sub {
                $echo_response = $_[1];
            });
        }
    });

    my $timeout = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->croak("timeout") };
    $cv->recv;

    ok $got_io, 'upgrade: handler was called and got io handle';
    ok $got_upgrade, 'upgrade: client received 101 Switching Protocols';
    is $upgrade_data, 'hello from client', 'upgrade: server received upgrade data';
    is $echo_response, 'echo: hello from client', 'upgrade: client received echo response';
    like $double_call_error, qr/io\(\) already called/, 'upgrade: calling io() twice throws error';
}

#######################################################################
# PART 2: Test return_from_io() for keepalive after io() access
#######################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'return: made listen socket';

    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);

    my $cv = AE::cv;
    my $request_count = 0;
    my $return_result;
    my @kept_ios;

    $feer->request_handler(sub {
        my $req = shift;
        $request_count++;

        if ($request_count == 1) {
            # First request: get io(), read some data, then return control
            my $io = $req->io;
            isa_ok $io, 'IO::Socket', 'return: got io handle';

            # Read the extra data sent after headers (use read, not sysread, for PerlIO)
            my $extra;
            read $io, $extra, 6;
            is $extra, 'SECRET', 'return: read extra data from io';

            # Return control to Feersum for keepalive
            $return_result = $req->return_from_io($io);
            ok defined($return_result), 'return: return_from_io returned';

            # Send response manually (we still have the io handle)
            $io->autoflush(1);
            print $io "HTTP/1.1 200 OK${CRLF}Content-Type: text/plain${CRLF}Content-Length: 2${CRLF}Connection: keep-alive${CRLF}${CRLF}OK";

            push @kept_ios, $io;  # Keep reference to prevent close
        }
        elsif ($request_count == 2) {
            # Second request on same keepalive connection
            pass 'return: received second request on keepalive connection';
            $req->send_response(200, ['Content-Type' => 'text/plain'], 'KEEPALIVE');
            # Don't cv->send here - let client finish reading
        }
    });

    # Client: send request with extra data, then keepalive request
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->croak("client error: $_[2]") },
    );

    # First request with extra data after headers
    my $req1 = "GET /test HTTP/1.1${CRLF}Host: localhost${CRLF}Connection: keep-alive${CRLF}${CRLF}SECRET";
    $h->push_write($req1);

    # Read first response
    $h->push_read(regex => qr/\r\n\r\n/, sub {
        my $headers = $_[1];
        if ($headers =~ /200 OK/) {
            $h->push_read(chunk => 2, sub {
                my $body = $_[1];
                is $body, 'OK', 'return: got first response body';

                # Send second request on keepalive connection
                my $req2 = "GET /keepalive HTTP/1.1${CRLF}Host: localhost${CRLF}Connection: close${CRLF}${CRLF}";
                $h->push_write($req2);

                # Read second response
                $h->push_read(regex => qr/\r\n\r\n/, sub {
                    $h->push_read(chunk => 9, sub {
                        is $_[1], 'KEEPALIVE', 'return: got keepalive response body';
                        $cv->send;  # Done - client finished reading
                    });
                });
            });
        }
    });

    my $timeout = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->croak("timeout") };
    $cv->recv;

    is $request_count, 2, 'return: received both requests';
}
