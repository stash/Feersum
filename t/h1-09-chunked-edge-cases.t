#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 26;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

#######################################################################
# Test chunked encoding edge cases for security and robustness
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
    my $resp = "len=" . length($body) . ",body=$body";
    $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
});

# Helper to send raw request and get response
sub raw_request {
    my ($request, $timeout) = @_;
    $timeout ||= 3;

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
# Test: Chunk extensions should be ignored (RFC 7230)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "5;ext=value\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk with extension gets 200 OK');
    like($response, qr/len=5/, 'Chunk extension: body length is 5');
    like($response, qr/body=hello/, 'Chunk extension: body is "hello"');
}

#######################################################################
# Test: Mixed case hex in chunk size
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "A\r\n0123456789\r\na\r\nabcdefghij\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Mixed case hex gets 200 OK');
    like($response, qr/len=20/, 'Mixed case: body length is 20');
}

#######################################################################
# Test: Uppercase hex in chunk size
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "F\r\n0123456789ABCDE\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Uppercase hex F (15) works');
    like($response, qr/len=15/, 'Uppercase: body length is 15');
}

#######################################################################
# Test: Empty body (just terminating chunk)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Empty chunked body gets 200 OK');
    like($response, qr/len=0/, 'Empty chunked: body length is 0');
}

#######################################################################
# Test: Missing CRLF after chunk data - should error
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "5\r\nhello5\r\nworld\r\n0\r\n\r\n"  # Missing CRLF after "hello"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Missing CRLF after chunk data gets 400');
}

#######################################################################
# Test: Invalid hex in chunk size
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "ZZ\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Invalid hex ZZ in chunk size gets 400');
}

#######################################################################
# Test: Chunk size overflow (too many hex digits)
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "FFFFFFFFFFFFFFFFFF\r\nhello\r\n0\r\n\r\n"  # 18 F's would overflow UV
    );
    like($response, qr/HTTP\/1\.1 400/, 'Chunk size overflow (too many hex digits) gets 400');
}

#######################################################################
# Test: Chunk with trailer headers
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\nTrailer: value\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunked with trailer gets 200 OK');
    like($response, qr/body=hello/, 'Trailer: body is "hello"');
}

#######################################################################
# Test: Multiple trailer headers
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\nX-Checksum: abc\r\nX-Footer: xyz\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Multiple trailers get 200 OK');
}

#######################################################################
# Test: Many small chunks
#######################################################################

{
    my $chunks = "";
    for my $i (1..100) {
        $chunks .= "1\r\n$i\r\n" if $i < 10;  # single digit for size 1
    }
    # Actually, let's use single character chunks
    $chunks = "";
    for (1..50) {
        $chunks .= "1\r\na\r\n";
    }
    $chunks .= "0\r\n\r\n";

    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        $chunks
    );
    like($response, qr/HTTP\/1\.1 200/, 'Many small chunks get 200 OK');
    like($response, qr/len=50/, 'Many small chunks: body length is 50');
}

#######################################################################
# Test: Large chunk size (but valid)
#######################################################################

{
    my $body = "x" x 1000;
    my $hex_size = sprintf("%x", 1000);  # "3e8"
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "$hex_size\r\n$body\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Large chunk (1000 bytes) gets 200 OK');
    like($response, qr/len=1000/, 'Large chunk: body length is 1000');
}

#######################################################################
# Test: Chunk size with no hex digits (only extension) - should error
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        ";ext=value\r\nhello\r\n0\r\n\r\n"  # Missing hex digits before extension
    );
    like($response, qr/HTTP\/1\.1 400/, 'Chunk size with no hex digits (only extension) gets 400');
}

#######################################################################
# Test: Chunk size with whitespace only - should error
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "   \r\nhello\r\n0\r\n\r\n"  # Only whitespace, no hex digits
    );
    like($response, qr/HTTP\/1\.1 400/, 'Chunk size with whitespace only gets 400');
}

#######################################################################
# Test: Empty chunk size line - should error
#######################################################################

{
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "\r\nhello\r\n0\r\n\r\n"  # Empty line where chunk size should be
    );
    like($response, qr/HTTP\/1\.1 400/, 'Empty chunk size line gets 400');
}

#######################################################################
# Test: EOF/truncation during chunked parsing (connection closes mid-chunk)
#######################################################################

{
    # Send partial chunk data then close connection
    my $cv = AE::cv;
    my $response = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );

    # Send headers and start of chunked body, but don't complete it
    $h->push_write(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" .
        "10\r\nhello"  # Claim 16 bytes but only send 5, then EOF
    );

    # Close write side to simulate EOF
    $h->push_shutdown;

    $h->on_read(sub {
        $response .= $h->rbuf;
        $h->rbuf = '';
    });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    # Server should handle EOF gracefully - either timeout, 400, or just close
    # The key is it shouldn't crash
    # Was a bare ok(1) with $response captured and discarded: the one thing
    # that must not happen is a 2xx for a body that never arrived.
    ok($response eq '' || $response =~ m{^HTTP/1\.[01] (?:400|408)},
       'EOF mid-chunk: connection closed or 4xx, never a success status');
}

{
    # Verify server still works after truncated request
    my $response = raw_request(
        "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Server still works after truncated chunked request');
}

pass "all chunked edge case tests completed";
