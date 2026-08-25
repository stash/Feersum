#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 25;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

#######################################################################
# PART 1: Native Feersum interface tests
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'native: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->request_handler(sub {
        my $r = shift;
        my $env = $r->env;
        my $body = '';
        if (my $cl = $env->{CONTENT_LENGTH}) {
            $env->{'psgi.input'}->read($body, $cl);
        }
        my $resp = "len=" . length($body) . ",body=$body";
        $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
    });

    # Test 1: Simple chunked request - one chunk
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "5\r\nhello\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/200 OK/, 'native: Got 200 OK response');
        like($response, qr/len=5/, 'native: Content length is 5');
        like($response, qr/body=hello/, 'native: Body is "hello"');
    }

    # Test 2: Multiple chunks
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=11/, 'native: Content length is 11');
        like($response, qr/body=hello world/, 'native: Body is "hello world"');
    }

    # Test 3: Hex chunk sizes (uppercase)
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "A\r\n0123456789\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=10/, 'native: Content length is 10 (hex A)');
        like($response, qr/body=0123456789/, 'native: Body is "0123456789"');
    }

    # Test 4: Malformed chunked encoding (invalid hex) should return 400
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "XYZ\r\nhello\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /HTTP\/1\.\d \d{3}/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/400 Bad Request/, 'native: Malformed chunked encoding returns 400');
    }

    # Test 5: Chunked with trailer headers (should be skipped)
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "5\r\nhello\r\n0\r\nX-Trailer: value\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=5/, 'native: Chunked with trailer works');
        like($response, qr/body=hello/, 'native: Body with trailer is correct');
    }
}

#######################################################################
# PART 2: PSGI interface tests
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'psgi: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);

    my $app = sub {
        my $env = shift;
        my $body = '';
        if (my $cl = $env->{CONTENT_LENGTH}) {
            $env->{'psgi.input'}->read($body, $cl);
        }
        my $resp = "len=" . length($body) . ",body=$body";
        return [200, ['Content-Type' => 'text/plain'], [$resp]];
    };

    $feer->psgi_request_handler($app);

    # Test 1: Simple chunked request - one chunk
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "5\r\nhello\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/200 OK/, 'psgi: Got 200 OK response');
        like($response, qr/len=5/, 'psgi: Content length is 5');
        like($response, qr/body=hello/, 'psgi: Body is "hello"');
    }

    # Test 2: Multiple chunks
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=11/, 'psgi: Content length is 11');
        like($response, qr/body=hello world/, 'psgi: Body is "hello world"');
    }

    # Test 3: Hex chunk sizes (uppercase)
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "A\r\n0123456789\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=10/, 'psgi: Content length is 10 (hex A)');
        like($response, qr/body=0123456789/, 'psgi: Body is "0123456789"');
    }

    # Test 4: Empty chunked body
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /len=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=0/, 'psgi: Empty chunked body has length 0');
    }

    # Test 5: Malformed chunked encoding (invalid hex) should return 400
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "XYZ\r\nhello\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /HTTP\/1\.\d \d{3}/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/400 Bad Request/, 'psgi: Malformed chunked encoding returns 400');
    }

    # Test 6: Lowercase hex chunk sizes
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "a\r\n0123456789\r\n0\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=10/, 'psgi: Lowercase hex (a=10) works');
        like($response, qr/body=0123456789/, 'psgi: Body with lowercase hex is correct');
    }

    # Test 7: Chunked with trailer headers (should be skipped)
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        my $chunked_body = "5\r\nhello\r\n0\r\nX-Trailer: value\r\n\r\n";
        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /body=/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=5/, 'psgi: Chunked with trailer works');
        like($response, qr/body=hello/, 'psgi: Body with trailer is correct');
    }
}
