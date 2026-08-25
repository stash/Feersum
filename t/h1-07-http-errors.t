#!/usr/bin/env perl
use strict;
use warnings;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More tests => 31;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

#######################################################################
# Test HTTP error responses: 400, 405, 411, 501, and related edge cases
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    if (my $cl = $env->{CONTENT_LENGTH}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"OK: $body");
});

# Helper to send raw request and get response
sub raw_request {
    my ($request, $timeout) = @_;
    $timeout ||= 3 * TIMEOUT_MULT;

    my $cv = AE::cv;
    my $response = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );

    $h->push_write($request);

    $h->on_read(sub {
        $response .= $h->rbuf;
        $h->rbuf = '';
    });

    my $timer = AE::timer $timeout, 0, sub { $cv->send; };
    $cv->recv;

    return $response;
}

#######################################################################
# Test 411 Length Required - POST without Content-Length or chunked
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 411/, '411: POST without Content-Length gets 411');
    like($response, qr/Length Required/i, '411: Contains "Length Required" message');
}

#######################################################################
# Test: POST with Content-Length: 0 should work (not 411)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'POST with Content-Length: 0 gets 200 OK');
    like($response, qr/OK:/, 'POST with empty body processes correctly');
}

#######################################################################
# Test: PUT without Content-Length should get 411
#######################################################################

{
    my $response = raw_request(
        "PUT /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 411/, '411: PUT without Content-Length gets 411');
}

#######################################################################
# Test: PATCH without Content-Length should get 411
#######################################################################

{
    my $response = raw_request(
        "PATCH /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 411/, '411: PATCH without Content-Length gets 411');
}

#######################################################################
# Test 501: Unsupported Transfer-Encoding
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 501/, '501: Unsupported Transfer-Encoding: gzip gets 501');
    like($response, qr/Not Implemented/i, '501: Contains "Not Implemented" message');
}

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: deflate\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 501/, '501: Unsupported Transfer-Encoding: deflate gets 501');
}

#######################################################################
# Test: Transfer-Encoding: chunked should work (not 501)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Transfer-Encoding: chunked gets 200 OK');
    like($response, qr/OK: hello/, 'Chunked body processed correctly');
}

#######################################################################
# Test 400: Invalid Content-Length (non-numeric)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, '400: Non-numeric Content-Length gets 400');
}

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: -5\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, '400: Negative Content-Length gets 400');
}

#######################################################################
# Test 400: Multiple conflicting Content-Length headers (RFC 7230)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 10\r\nConnection: close\r\n\r\nhello"
    );
    like($response, qr/HTTP\/1\.1 400/, '400: Multiple conflicting Content-Length headers gets 400');
}

{
    # Same value should be OK (some proxies may add duplicate headers)
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Multiple identical Content-Length headers is OK');
}

#######################################################################
# Test: GET without body headers should work (no 411)
#######################################################################

{
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'GET without Content-Length gets 200 OK');
}

#######################################################################
# Test: HEAD request should work
#######################################################################

{
    my $response = raw_request(
        "HEAD /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'HEAD request gets 200 OK');
    # Note: Feersum relies on the PSGI app to not send a body for HEAD requests
    # The server itself doesn't suppress the body (PSGI spec responsibility)
    like($response, qr/Content-Length:/, 'HEAD response has Content-Length header');
}

#######################################################################
# Test: DELETE request should work (body optional per RFC)
#######################################################################

{
    my $response = raw_request(
        "DELETE /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'DELETE without body gets 200 OK');
}

#######################################################################
# Test: OPTIONS request should work
#######################################################################

{
    my $response = raw_request(
        "OPTIONS /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'OPTIONS request gets 200 OK');
}

#######################################################################
# Test: PATCH request with body should work
#######################################################################

{
    my $response = raw_request(
        "PATCH /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nConnection: close\r\n\r\npatch"
    );
    like($response, qr/HTTP\/1\.1 200/, 'PATCH with body gets 200 OK');
    like($response, qr/OK: patch/, 'PATCH body processed correctly');
}

#######################################################################
# Test: Custom/unknown method - Feersum returns 405 Method Not Allowed
#######################################################################

{
    my $response = raw_request(
        "CUSTOM /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 405/, '405: Unknown method gets Method Not Allowed');
}

#######################################################################
# Test: Malformed request line
#######################################################################

{
    my $response = raw_request(
        "GET\r\nHost: localhost\r\n\r\n"
    );
    # Malformed - no URI
    # An empty response meant "server wedged on a malformed request line"
    # and still passed.  raw_request returns '' on its own timeout.
    like($response, qr{^HTTP/1\.[01] 400},
       'Malformed request (no URI) rejected with 400');
}

#######################################################################
# Test: 204 No Content - must not have Content-Length
#######################################################################

{
    # Use a separate server with a 204-returning handler
    my ($socket204, $port204) = get_listen_socket();
    ok $socket204, '204: made listen socket';

    my $feer204 = Feersum->new();
    $feer204->use_socket($socket204);
    $feer204->request_handler(sub {
        my $r = shift;
        $r->send_response(204, ['X-Custom' => 'yes'], []);
    });

    my $response = '';
    my $cv = AE::cv;
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port204],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { $response .= $h->rbuf; $h->rbuf = ''; });
    my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    like($response, qr/HTTP\/1\.1 204/, '204: got 204 No Content');
    unlike($response, qr/Content-Length/i, '204: no Content-Length header');
}

#######################################################################
# Duplicate Host header -> 400 (RFC 7230 section 5.4)
#######################################################################
{
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: a.example.com\r\nHost: b.example.com\r\nConnection: close\r\n\r\n"
    );
    like $response, qr/^HTTP\/1\.\d 400/m, 'duplicate Host header -> 400';
    like $response, qr/Duplicate Host/i, 'duplicate Host: error message';
}

pass "all error handling tests completed";
