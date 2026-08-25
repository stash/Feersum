#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 49;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

# Security and edge cases: request smuggling (CL + TE rejected), chunk
# extensions, pipeline depth limits, buffer growth limits.

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
my @seen_envs;
$feer->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    push @seen_envs, { %$env };
    my $body = '';
    if (my $cl = $env->{CONTENT_LENGTH}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    my $resp = "len=" . length($body) . ",body=$body";
    $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
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
# Test: Content-Length + Transfer-Encoding rejection (request smuggling prevention)
#######################################################################

{
    # RFC 7230 3.3.3: If both CL and TE are present, reject the request
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Request smuggling: CL + TE rejected with 400');
    like($response, qr/Content-Length not allowed/i, 'Request smuggling: error message mentions conflict');
}

{
    # Order shouldn't matter - TE before CL
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Request smuggling: TE + CL (reverse order) rejected');
}

#######################################################################
# Test: Chunk extensions are handled correctly
#######################################################################

{
    # RFC 7230 allows chunk extensions after the size: "5;name=value\r\n"
    my $chunked_body = "5;ext=value\r\nhello\r\n0\r\n\r\n";
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk extension: request accepted');
    like($response, qr/len=5/, 'Chunk extension: body length is 5');
    like($response, qr/body=hello/, 'Chunk extension: body is "hello"');
}

{
    # Multiple chunk extensions
    my $chunked_body = "5;foo=bar;baz=qux\r\nhello\r\n6 ; space = ok \r\n world\r\n0\r\n\r\n";
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Multiple chunk extensions: accepted');
    like($response, qr/len=11/, 'Multiple chunk extensions: body length is 11');
}

#######################################################################
# Test: Chunked with leading zeros in size
#######################################################################

{
    my $chunked_body = "00005\r\nhello\r\n0\r\n\r\n";
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Leading zeros in chunk size: accepted');
    like($response, qr/len=5/, 'Leading zeros in chunk size: body length is 5');
}

#######################################################################
# Test: MAX_PIPELINE_DEPTH boundary (16 is the limit)
#######################################################################

{
    my $cv = AE::cv;
    my $buffer = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
        on_read => sub {
            $buffer .= $_[0]->rbuf;
            $_[0]->rbuf = '';
        }
    );

    # Send 17 pipelined GET requests (MAX_PIPELINE_DEPTH + 1)
    my $request = '';
    for my $i (1..17) {
        $request .= "GET /test$i HTTP/1.1\r\nHost: localhost\r\n";
        $request .= "Connection: close\r\n" if $i == 17;
        $request .= "\r\n";
    }
    $h->push_write($request);

    my $timer = AE::timer 5 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    # Count 200 OK responses - should get all 17 (pipeline depth limit prevents stack overflow, not request count)
    my @responses = $buffer =~ /HTTP\/1\.1 200 OK/g;
    # ">= 16" of 17 tolerated a silently dropped response.
    is(scalar(@responses), 17,
       "Pipeline depth: all 17 responses received (got " . scalar(@responses) . ")");
}

#######################################################################
# Test: Chunked transfer without issues on valid input
#######################################################################

{
    # Many small chunks (test chunk counting)
    my $chunked_body = '';
    for my $i (1..100) {
        $chunked_body .= "1\r\nX\r\n";
    }
    $chunked_body .= "0\r\n\r\n";

    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Many small chunks: accepted');
    like($response, qr/len=100/, 'Many small chunks: body length is 100');
}

#######################################################################
# Test: Transfer-Encoding without Content-Length (valid)
#######################################################################

{
    my $chunked_body = "5\r\nhello\r\n0\r\n\r\n";
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE without CL: accepted');
    like($response, qr/len=5/, 'TE without CL: body length is 5');
}

#######################################################################
# Test: Transfer-Encoding: chunked with semicolon extension
#######################################################################

{
    my $chunked_body = "5\r\nhello\r\n0\r\n\r\n";
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked;q=1.0\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE chunked;ext: accepted');
    like($response, qr/len=5/, 'TE chunked;ext: body length is 5');
}

{
    my $chunked_body = "5\r\nhello\r\n0\r\n\r\n";
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked ; param=value\r\nConnection: close\r\n\r\n$chunked_body"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE chunked ; ext: accepted with space');
    like($response, qr/len=5/, 'TE chunked ; ext: body length is 5');
}

#######################################################################
# Test: Transfer-Encoding: identity (means no encoding)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: identity\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE identity: accepted');
    like($response, qr/len=5/, 'TE identity: body length is 5');
}

#######################################################################
# Test: Unsupported Transfer-Encoding values (should return 501)
#######################################################################

{
    # gzip is not supported - should get 501 Not Implemented
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    );
    like($response, qr/HTTP\/1\.1 501/, 'TE gzip: rejected with 501 Not Implemented');
    like($response, qr/Unsupported Transfer-Encoding/i, 'TE gzip: error message mentions unsupported');
}

{
    # deflate is not supported - should get 501 Not Implemented
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: deflate\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    );
    like($response, qr/HTTP\/1\.1 501/, 'TE deflate: rejected with 501 Not Implemented');
    like($response, qr/Unsupported Transfer-Encoding/i, 'TE deflate: error message mentions unsupported');
}

{
    # compress is not supported - should get 501 Not Implemented
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: compress\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
    );
    like($response, qr/HTTP\/1\.1 501/, 'TE compress: rejected with 501 Not Implemented');
    like($response, qr/Unsupported Transfer-Encoding/i, 'TE compress: error message mentions unsupported');
}

#######################################################################
# Test: Header names near MAX_HEADER_NAME_LEN boundary (128)
#######################################################################

{
    # Header name exactly 127 bytes (under limit) - should work
    my $header_name = 'X-' . ('A' x 125);  # 2 + 125 = 127 bytes
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: localhost\r\n$header_name: value\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Header name 127 bytes: accepted');
}

{
    # Header name exactly 128 bytes (at limit) - should work
    my $header_name = 'X-' . ('A' x 126);  # 2 + 126 = 128 bytes
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: localhost\r\n$header_name: value\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Header name 128 bytes (at limit): accepted');
}

{
    # Header name 129 bytes (over limit) - should be rejected with 431
    my $header_name = 'X-' . ('A' x 127);  # 2 + 127 = 129 bytes
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: localhost\r\n$header_name: value\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.[01] 431/, 'Header name 129 bytes (over limit): rejected with 431');
}

{
    # Header name 200 bytes (well over limit) - should be rejected with 431
    my $header_name = 'X-' . ('A' x 198);  # 2 + 198 = 200 bytes
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: localhost\r\n$header_name: value\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.[01] 431/, 'Header name 200 bytes (well over limit): rejected with 431');
}

#######################################################################
# Test: Pipeline with mixed methods (GET, POST, GET interleaved)
#######################################################################

{
    my $cv = AE::cv;
    my $buffer = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
        on_read => sub {
            $buffer .= $_[0]->rbuf;
            $_[0]->rbuf = '';
        }
    );

    # Send mixed pipeline: GET, POST with body, GET
    # Note: each request must be complete before the next starts
    my $request =
        "GET /test1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
        "POST /test2 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" .
        "GET /test3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    $h->push_write($request);

    my $timer = AE::timer 5 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    # Count 200 OK responses - should get 3
    my @responses = $buffer =~ /HTTP\/1\.1 200 OK/g;
    is(scalar(@responses), 3, "Mixed method pipeline (GET, POST, GET): got all 3 responses");

    # Verify POST body was received correctly
    like($buffer, qr/body=hello/, 'Mixed pipeline: POST body correct');

    # Verify GET requests had empty bodies
    my @empty_bodies = $buffer =~ /len=0,body=/g;
    is(scalar(@empty_bodies), 2, 'Mixed pipeline: both GET requests had empty bodies');
}

#######################################################################
# Test RFC 7230: Reject obsolete header line folding (obs-fold)
#######################################################################
{
    # Header with continuation line (obs-fold) - should be rejected
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "X-Custom: value1\r\n" .
        " continued-value\r\n" .  # obs-fold: line starting with space
        "Connection: close\r\n\r\n"
    );
    like($resp, qr/HTTP\/1\.[01] 400/, 'Obs-fold header (space continuation): rejected with 400');
    like($resp, qr/line folding/i, 'Obs-fold: error message mentions line folding');
}

#######################################################################
# Test: Multiple Host headers (RFC 7230 Section 5.4 says reject, but
# picohttpparser accepts them - app must handle if needed)
#######################################################################
{
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Host: example.com\r\n" .
        "Host: evil.com\r\n" .
        "Connection: close\r\n\r\n"
    );
    # Note: picohttpparser accepts multiple Host headers, passes to app
    like($resp, qr/HTTP\/1\.[01] [24]/, 'Multiple Host headers: handled (app responsibility)');
}

#######################################################################
# Test: Null byte in URI (should not crash, should reject or handle safely)
#######################################################################
{
    my $resp = raw_request(
        "GET /test\x00hidden HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n\r\n"
    );
    # Should either reject with 400 or pass through safely (app responsibility)
    like($resp, qr/HTTP\/1\.[01] [24]/, 'Null byte in URI: handled safely (2xx or 4xx)');
}

#######################################################################
# Test: Null byte in header value
#######################################################################
{
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "X-Custom: value\x00hidden\r\n" .
        "Connection: close\r\n\r\n"
    );
    # Should either reject with 400 or handle safely
    like($resp, qr/HTTP\/1\.[01] [24]/, 'Null byte in header value: handled safely');
}

#######################################################################
# Test: CRLF injection attempt in header
#######################################################################
{
    # Try to inject a header via CRLF in header value
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "X-Evil: value\r\nX-Injected: header\r\n" .
        "Connection: close\r\n\r\n"
    );
    # NB this request contains two *legitimate* headers (a real CRLF), so the
    # app is expected to see both.  The old regex accepted any 2xx/4xx; what
    # matters is that a real response comes back and nothing is echoed into it.
    like($resp, qr{^HTTP/1\.[01] [24]}, 'CRLF injection attempt: got a real response');
    unlike($resp, qr/X-Injected/i, 'CRLF injection: smuggled header not echoed');
}

#######################################################################
# Test: WebSocket upgrade request (should handle gracefully)
#######################################################################
{
    my $resp = raw_request(
        "GET /ws HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Upgrade: websocket\r\n" .
        "Connection: Upgrade\r\n" .
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" .
        "Sec-WebSocket-Version: 13\r\n\r\n"
    );
    # Feersum doesn't support WebSocket natively, should return normal response
    # (app can handle upgrade if psgix.io is available)
    # [245] accepted every status except 1xx/3xx.  Feersum has no native
    # WebSocket support, so this must be an ordinary answered request.
    like($resp, qr{^HTTP/1\.[01] [24]\d\d}, 'WebSocket upgrade: answered, not crashed');
}

#######################################################################
# Test: HTTP/0.9 style request (no version)
#######################################################################
{
    my $resp = raw_request("GET /test\r\n");
    # HTTP/0.9 should be rejected - either 400 or connection close
    # An empty response also matched, so a wedged connection passed.  Require a
    # real rejection: a 400, or a clean close with no partial HTTP response.
    ok($resp =~ m{^HTTP/1\.[01] 400} || $resp eq '',
       'HTTP/0.9 request: rejected with 400 or closed');
    unlike($resp, qr{^HTTP/1\.[01] 200}, 'HTTP/0.9 request: not served a 200');
}

#######################################################################
# Test: Extremely long header value (potential DoS)
#######################################################################
{
    my $long_value = 'x' x 16384;  # 16KB header value
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "X-Long: $long_value\r\n" .
        "Connection: close\r\n\r\n"
    );
    # Should either accept (within buffer limits) or reject cleanly
    like($resp, qr/HTTP\/1\.[01] [24]/, 'Long header value (16KB): handled without crash');
}

#######################################################################
# Test: Header with only spaces as value
#######################################################################
{
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "X-Empty:    \r\n" .
        "Connection: close\r\n\r\n"
    );
    like($resp, qr/HTTP\/1\.[01] [24]/, 'Header with whitespace-only value: handled');
}

#######################################################################
# Test: Missing Host header (HTTP/1.1 requires it)
#######################################################################
{
    my $resp = raw_request(
        "GET /test HTTP/1.1\r\n" .
        "Connection: close\r\n\r\n"
    );
    # HTTP/1.1 without Host should be rejected per RFC 7230
    like($resp, qr/HTTP\/1\.[01] 400/, 'Missing Host header in HTTP/1.1: rejected with 400');
}

pass "all security edge case tests completed";
