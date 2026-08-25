#!/usr/bin/env perl
# Edge case tests for force_http10/11 and pipeline depth limits
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 14;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
$feer->read_timeout(3.0);

#######################################################################
# Edge Case 1: force_http10 then force_http11 (last one wins)
#######################################################################
{
    my $cv = AE::cv;
    my $response_protocol;

    $feer->request_handler(sub {
        my $r = shift;
        $r->force_http10;  # first call
        $r->force_http11;  # second call should override
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'test');
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->push_read(line => "\r\n", sub {
        $response_protocol = $_[1];
        $h->on_read(sub {});
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
    like $response_protocol, qr{^HTTP/1\.1 200}, 'force_http10 then force_http11: last one wins (HTTP/1.1)';
}

#######################################################################
# Edge Case 2: force_http11 then force_http10 (last one wins)
#######################################################################
{
    my $cv = AE::cv;
    my $response_protocol;

    $feer->request_handler(sub {
        my $r = shift;
        $r->force_http11;  # first call
        $r->force_http10;  # second call should override
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'test');
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->push_read(line => "\r\n", sub {
        $response_protocol = $_[1];
        $h->on_read(sub {});
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
    like $response_protocol, qr{^HTTP/1\.0 200}, 'force_http11 then force_http10: last one wins (HTTP/1.0)';
}

#######################################################################
# Edge Case 3: Multiple calls to same force_http method (idempotent)
#######################################################################
{
    my $cv = AE::cv;
    my $response_protocol;

    $feer->request_handler(sub {
        my $r = shift;
        $r->force_http10;
        $r->force_http10;  # redundant call
        $r->force_http10;  # another redundant call
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'test');
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->push_read(line => "\r\n", sub {
        $response_protocol = $_[1];
        $h->on_read(sub {});
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
    like $response_protocol, qr{^HTTP/1\.0 200}, 'multiple force_http10 calls: idempotent';
}

#######################################################################
# Edge Case 4: force_http10 with streaming (should not use chunked)
#######################################################################
{
    my $cv = AE::cv;
    my $headers = '';
    my $body = '';

    $feer->request_handler(sub {
        my $r = shift;
        $r->force_http10;  # Force HTTP/1.0 even though request is 1.1
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("stream1");
        $w->write("stream2");
        $w->close();
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->croak("error: $_[2]") },
    );
    $h->push_write("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    $h->push_read(regex => qr/\r\n\r\n/, sub {
        $headers = $_[1];
        $h->on_read(sub {
            $body .= $h->rbuf;
            $h->rbuf = '';
        });
        $h->on_eof(sub { $cv->send });
    });

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { Test::More::fail("timed out"); $cv->send };
    eval { $cv->recv };
    ok !$@, 'force_http10 streaming: no error' or diag $@;
    like $headers, qr{^HTTP/1\.0 200}m, 'force_http10 streaming: response is HTTP/1.0';
    unlike $headers, qr/Transfer-Encoding:\s*chunked/i, 'force_http10 streaming: no chunked encoding';
    is $body, 'stream1stream2', 'force_http10 streaming: body received correctly';
}

#######################################################################
# Edge Case 5: force_http11 with streaming from HTTP/1.0 client (gets chunked)
#######################################################################
{
    my $cv = AE::cv;
    my $headers = '';
    my $body = '';

    $feer->request_handler(sub {
        my $r = shift;
        $r->force_http11;  # Force HTTP/1.1 even though request is 1.0
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("data1");
        $w->write("data2");
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

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { Test::More::fail("timed out"); $cv->send };
    eval { $cv->recv };
    ok !$@, 'force_http11 streaming: no error' or diag $@;
    like $headers, qr{^HTTP/1\.1 200}m, 'force_http11 streaming: response is HTTP/1.1';
    like $headers, qr/Transfer-Encoding:\s*chunked/i, 'force_http11 streaming: has chunked encoding';
}

#######################################################################
# Edge Case 6: Pipeline depth limit (MAX_PIPELINE_DEPTH = 15)
# Send 20 pipelined requests, all should be handled gracefully
#######################################################################
{
    my $cv = AE::cv;
    my $buffer = '';
    my $request_count = 0;

    $feer->request_handler(sub {
        my $r = shift;
        $request_count++;
        $r->send_response(200, ['Content-Type' => 'text/plain'], "resp$request_count");
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub { $cv->croak("error: $_[2]") },
    );

    # Build 20 pipelined requests
    my $pipeline = '';
    for my $i (1..19) {
        $pipeline .= "GET /req$i HTTP/1.1\r\nHost: localhost\r\n\r\n";
    }
    $pipeline .= "GET /req20 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    $h->push_write($pipeline);
    $h->on_read(sub {
        $buffer .= $h->rbuf;
        $h->rbuf = '';
    });
    $h->on_eof(sub { $cv->send });

    my $timeout = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    # Count responses
    my @responses = $buffer =~ /HTTP\/1\.1 200 OK/g;
    my $response_count = scalar(@responses);

    # All pipelined requests must be answered.  ">= 16" of 20 silently
    # tolerated four dropped responses - exactly the defect this file exists
    # to catch.
    is $response_count, 20, "pipeline depth: all 20 requests answered (got $response_count)";
}

pass 'all edge case tests completed';
