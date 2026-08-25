#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 17;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

# DoS protection limits: many chunks (MAX_CHUNK_COUNT smoke), MAX_TRAILER_HEADERS,
# MAX_HEADERS, write() after close().  The exact MAX_CHUNK_COUNT (100,000) is
# impractical here; the trailer test covers the same chunked error path.

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
    my $resp = "len=" . length($body) . ",body_start=" . substr($body, 0, 20);
    $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
});

# Helper to send raw request and get response
sub raw_request {
    my ($request, $timeout) = @_;
    $timeout ||= 10;

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
# Test: Many chunks work correctly (smoke test for chunk counting)
# This verifies the chunk counting code path without hitting limits
#######################################################################

{
    # Build 1000 single-byte chunks (well under the 100K limit)
    my $chunks = '';
    for (1..1000) {
        $chunks .= "1\r\nX\r\n";
    }
    $chunks .= "0\r\n\r\n";

    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n$chunks"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Many chunks (1000): accepted');
    like($response, qr/len=1000/, 'Many chunks: body length correct');
}

# Verify server still works after chunk limit test
{
    my $response = raw_request(
        "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Server still works after chunk limit test');
}

#######################################################################
# Test: MAX_TRAILER_HEADERS limit (64 trailer headers)
# Sending 65 trailer headers should be rejected with 400
#######################################################################

{
    # Build chunked request with 65 trailer headers (exceeds limit of 64)
    my $trailers = '';
    for my $i (1..65) {
        $trailers .= "X-Trailer-$i: value$i\r\n";
    }

    my $request =
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n" .           # One data chunk
        "0\r\n" .                     # Final chunk
        $trailers .                   # 65 trailer headers
        "\r\n";                       # End of trailers

    my $response = raw_request($request);
    like($response, qr/HTTP\/1\.[01] 400/,
        'MAX_TRAILER_HEADERS: 65 trailers rejected with 400');
}

{
    # 64 trailer headers should be accepted (at the limit)
    my $trailers = '';
    for my $i (1..64) {
        $trailers .= "X-Trailer-$i: value$i\r\n";
    }

    my $request =
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n" .
        "0\r\n" .
        $trailers .
        "\r\n";

    my $response = raw_request($request);
    like($response, qr/HTTP\/1\.1 200/,
        'MAX_TRAILER_HEADERS: 64 trailers accepted (at limit)');
    like($response, qr/len=5/, 'MAX_TRAILER_HEADERS: body received correctly');
}

#######################################################################
# Test: MAX_HEADERS limit (64 headers per request)
# Sending 65+ headers should be rejected or truncated
#######################################################################

{
    # Pin the MAX_HEADERS boundary exactly.  Accepting "200 or 400" asserted
    # nothing - the limit could shrink to 8 and this stayed green - and the
    # count was off by one anyway, because Connection: close below is a header
    # too.  Host + Connection are 2, so 62 more is exactly at the limit.
    my $mk = sub {
        my ($extra) = @_;
        my $h = "Host: localhost\r\n";
        $h .= "X-Header-$_: value$_\r\n" for 1 .. $extra;
        return "GET /test HTTP/1.1\r\n" . $h . "Connection: close\r\n\r\n";
    };

    my ($at_limit) = raw_request($mk->(62)) =~ m{^HTTP/1\.[01] (\d+)};
    is $at_limit, 200, 'MAX_HEADERS: exactly 64 headers accepted';

    # 431, not 400: the request is well-formed, it just carries too many
    # fields (RFC 6585), and Feersum already answers 431 for an over-long
    # header name.  The boundary this test exists to pin is unchanged.
    my ($over) = raw_request($mk->(63)) =~ m{^HTTP/1\.[01] (\d+)};
    is $over, 431, q{MAX_HEADERS: 65 headers rejected with 431};
}

{
    # 65+ headers - should be rejected or truncated
    my $headers = "Host: localhost\r\n";
    for my $i (1..70) {  # Well over the limit
        $headers .= "X-Header-$i: value$i\r\n";
    }

    my $request =
        "GET /test HTTP/1.1\r\n" .
        $headers .
        "Connection: close\r\n\r\n";

    # "any non-empty bytes" added nothing over the 64/65 boundary pinned above,
    # and passed on a 500 or a truncated reply.  The block just above proves 65
    # is rejected, so 70 must be too.
    my ($status) = (raw_request($request) // '') =~ m{^HTTP/1\.[01] (\d+)};
    is $status, 431, 'MAX_HEADERS: 70 headers rejected with 431';
}

#######################################################################
# Test: write() after close() should not crash
# This tests the handle safety in Feersum::Connection::Handle
#######################################################################

{
    my $cv = AE::cv;
    my $write_after_close_error = '';
    my $crashed = 0;

    # Create a handler that closes the writer then tries to write again
    $feer->request_handler(sub {
        my $r = shift;
        eval {
            my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
            $w->write("first\n");
            $w->close();

            # This should error cleanly, not crash
            eval { $w->write("after close\n"); };
            $write_after_close_error = $@ || '';
        };
        if ($@) {
            $crashed = 1;
        }
        $cv->send;
    });

    # Send a request to trigger the handler
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    ok(!$crashed, 'write() after close(): did not crash');
    like($write_after_close_error, qr/closed/i,
        'write() after close(): got appropriate error message');
}

# Restore default handler
$feer->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    if (my $cl = $env->{CONTENT_LENGTH}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    my $resp = "len=" . length($body);
    $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
});

#######################################################################
# Test: Verify server stability after all DoS tests
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 11\r\n" .
        "Connection: close\r\n\r\n" .
        "hello world"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Server stable: POST request works');
    like($response, qr/len=11/, 'Server stable: body received correctly');
}

{
    # Chunked encoding still works
    my $response = raw_request(
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Server stable: chunked encoding works');
    like($response, qr/len=5/, 'Server stable: chunked body received');
}

pass "all DoS limit tests completed";
