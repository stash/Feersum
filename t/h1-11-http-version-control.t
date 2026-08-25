#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 15;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

#######################################################################
# Test force_http10, force_http11, and HTTP/1.0 streaming fallback
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

# Test 1: force_http10 causes HTTP/1.0 response for HTTP/1.1 request
{
    my $cv = AE::cv;
    my $response_protocol;
    my $handler_called = 0;

    $feer->request_handler(sub {
        my $r = shift;
        $handler_called = $r->is_http11 ? 1 : 0;
        $r->force_http10;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'test');
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },  # Accept errors after reading
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->push_read(line => "\r\n", sub {
        $response_protocol = $_[1];
        $h->on_read(sub {});
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
    ok $handler_called, 'force_http10: request was HTTP/1.1';
    like $response_protocol, qr{^HTTP/1\.0 200}, 'force_http10: response is HTTP/1.0';
}

# Test 2: force_http11 causes HTTP/1.1 response for HTTP/1.0 request
{
    my $cv = AE::cv;
    my $response_protocol;
    my $handler_called = 0;

    $feer->request_handler(sub {
        my $r = shift;
        $handler_called = $r->is_http11 ? 0 : 1;  # expect HTTP/1.0
        $r->force_http11;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'test');
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },  # Accept errors after reading
    );
    $h->push_write("GET /test HTTP/1.0\r\nHost: localhost\r\n\r\n");
    $h->push_read(line => "\r\n", sub {
        $response_protocol = $_[1];
        $h->on_read(sub {});
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
    ok $handler_called, 'force_http11: request was HTTP/1.0';
    like $response_protocol, qr{^HTTP/1\.1 200}, 'force_http11: response is HTTP/1.1';
}

# Test 3: HTTP/1.0 streaming uses Connection: close (not chunked)
{
    my $cv = AE::cv;
    my $headers = '';
    my $body = '';

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("chunk1");
        $w->write("chunk2");
        $w->close();
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->croak("error: $_[2]") },
    );
    $h->push_write("GET /stream HTTP/1.0\r\nHost: localhost\r\n\r\n");
    $h->push_read(regex => qr/\r\n\r\n/, sub {
        $headers = $_[1];
        $h->on_read(sub {
            $body .= $h->rbuf;
            $h->rbuf = '';
        });
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->croak("timeout") };
    eval { $cv->recv };
    ok !$@, 'no error' or diag $@;
    like $headers, qr{^HTTP/1\.0 200}m, 'HTTP/1.0 streaming: response is HTTP/1.0';
    unlike $headers, qr/Transfer-Encoding:\s*chunked/i, 'HTTP/1.0 streaming: no chunked encoding';
    is $body, 'chunk1chunk2', 'HTTP/1.0 streaming: body received without chunk framing';
}

# Test 4: HTTP/1.1 streaming uses Transfer-Encoding: chunked
{
    my $cv = AE::cv;
    my $headers = '';
    my $body = '';

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("chunk1");
        $w->write("chunk2");
        $w->close();
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->croak("error: $_[2]") },
    );
    $h->push_write("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->push_read(regex => qr/\r\n\r\n/, sub {
        $headers = $_[1];
        $h->on_read(sub {
            $body .= $h->rbuf;
            $h->rbuf = '';
        });
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->croak("timeout") };
    eval { $cv->recv };
    ok !$@, 'no error' or diag $@;
    like $headers, qr{^HTTP/1\.1 200}m, 'HTTP/1.1 streaming: response is HTTP/1.1';
    like $headers, qr/Transfer-Encoding:\s*chunked/i, 'HTTP/1.1 streaming: has chunked encoding';
    like $body, qr/chunk1.*chunk2/s, 'HTTP/1.1 streaming: body contains chunks';
}

pass 'all HTTP version control tests completed';
