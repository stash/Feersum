#!/usr/bin/env perl
# Assorted H1 edge cases: accept_on_fd, graceful shutdown with pipelining, TE
# smuggling/case/identity, chunked malformations/extensions/hex, trailers,
# max_connection_reqs, Expect, HTTP/1.0 TE, URI length, duplicate Content-Length.
use strict;
use warnings;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

BEGIN {
    plan skip_all => 'not applicable on win32'
        if $^O eq 'MSWin32';
}

plan tests => 77;

#######################################################################
# Helper: send raw request on a given port and return response
#######################################################################
sub raw_request {
    my ($port, $request, $timeout) = @_;
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
# Section 1: accept_on_fd() direct test
#######################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'accept_on_fd: got listen socket';

    my $feer = Feersum->new_instance();
    my $fd = fileno($socket);
    ok defined($fd), "accept_on_fd: socket has fileno: $fd";

    eval { $feer->accept_on_fd($fd) };
    ok !$@, 'accept_on_fd: succeeded' or diag $@;

    $feer->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'accept_on_fd works');
    });

    my $cv = AE::cv;
    my $response_ok = 0;
    my $body = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
        on_connect => sub {
            $_[0]->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            $_[0]->push_read(line => "\r\n", sub {
                $response_ok = 1 if $_[1] =~ /200 OK/;
                $_[0]->on_read(sub {
                    $body .= $_[0]->rbuf;
                    $_[0]->rbuf = '';
                });
                $_[0]->on_eof(sub { $cv->send });
            });
        },
    );

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok $response_ok, 'accept_on_fd: server responds with 200';
    like $body, qr/accept_on_fd works/, 'accept_on_fd: correct body';

    $feer->unlisten();
}

#######################################################################
# Section 2: Graceful shutdown with pipelined requests
#######################################################################
{
    my ($socket2, $port2) = get_listen_socket();
    ok $socket2, 'graceful shutdown: got listen socket';

    my $feer = Feersum->new_instance();
    $feer->use_socket($socket2);

    my $request_count = 0;
    my $shutdown_initiated = 0;

    $feer->request_handler(sub {
        my $r = shift;
        $request_count++;

        if ($request_count == 1 && !$shutdown_initiated) {
            $shutdown_initiated = 1;
            my $t; $t = AE::timer 0.05, 0, sub {
                $feer->graceful_shutdown(sub { });
                undef $t;
            };
        }

        $r->send_response(200, ['Content-Type' => 'text/plain'], "req $request_count");
    });

    my $cv = AE::cv;
    my @responses;

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port2],
        on_error => sub { $cv->send },
        on_eof => sub { $cv->send },
        on_connect => sub {
            $_[0]->push_write(
                "GET /1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
                "GET /2 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
                "GET /3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
            );
            $_[0]->on_read(sub {
                my $data = $_[0]->rbuf;
                $_[0]->rbuf = '';
                push @responses, $1 while $data =~ /(HTTP\/1\.1 \d+)/g;
            });
        },
    );

    my $timeout = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok $shutdown_initiated, 'graceful shutdown was initiated';
    cmp_ok $request_count, '>=', 1, 'at least one request was processed';
    cmp_ok scalar(@responses), '>=', 1, 'at least one response received';
    like $responses[0] || '', qr/200/, 'first pipelined response OK';
}

#######################################################################
# Set up main server for remaining tests
#######################################################################
my ($main_socket, $main_port) = get_listen_socket();
ok $main_socket, 'main server: made listen socket';

my $main_feer = Feersum->new_instance();
$main_feer->use_socket($main_socket);
$main_feer->set_keepalive(1);
$main_feer->max_connection_reqs(4);  # for max_connection_reqs test
$main_feer->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    if (my $cl = $env->{CONTENT_LENGTH}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    my $uri = $env->{REQUEST_URI} || '/';
    my $resp = "uri_len=" . length($uri) . ",body_len=" . length($body) . ",body=$body";
    $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
});

#######################################################################
# Section 3: Multiple Transfer-Encoding headers (request smuggling)
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Multiple TE headers (same value): rejected with 400');
    like($response, qr/Multiple Transfer-Encoding/i, 'Multiple TE headers: error message');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Transfer-Encoding: identity\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Multiple TE headers (different values): rejected with 400');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Transfer-Encoding: gzip\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Multiple TE headers (chunked+gzip smuggling): rejected');
}

#######################################################################
# Section 4: Chunked encoding malformations
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "GGG\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Chunked malformed: non-hex chunk size rejected');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Chunked malformed: empty chunk size rejected');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5xyz\r\nhello\r\n0\r\n\r\n"
    );
    # raw_request always returns a (possibly empty) string, so `defined` was a
    # tautology.  5xyz is 5 with a chunk extension, which is legal, so the
    # server must answer - and must not just drop the connection.
    like($response, qr{^HTTP/1\.[01] (?:200|400)},
         'Chunked with trailing chars: got a real HTTP response');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhelloX0\r\n\r\n"  # Missing CRLF after "hello"
    );
    # Malformed framing must be rejected, not silently accepted as 200.
    like($response, qr{^HTTP/1\.[01] 400},
         'Chunked missing CRLF after data: rejected with 400');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "-5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Chunked malformed: negative chunk size rejected');
}

#######################################################################
# Section 5: max_connection_reqs boundary (set to 4 above)
#######################################################################

{
    my $cv = AE::cv;
    my $buffer = '';
    my $responses_received = 0;

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $main_port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
        on_read => sub {
            $buffer .= $_[0]->rbuf;
            $_[0]->rbuf = '';
            $responses_received = () = $buffer =~ /HTTP\/1\.1 200 OK/g;
            $cv->send if $responses_received >= 4;
        }
    );

    for my $i (1..4) {
        $h->push_write("GET /req$i HTTP/1.1\r\nHost: localhost\r\n\r\n");
    }

    my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    my @responses = $buffer =~ /HTTP\/1\.1 200 OK/g;
    is(scalar(@responses), 4, 'max_connection_reqs: got exactly 4 responses');

    my @parts = split(/HTTP\/1\.1 200 OK/, $buffer);
    shift @parts;

    my $close_count = 0;
    for my $i (0..2) {
        if (defined $parts[$i] && $parts[$i] =~ /Connection: close/i) {
            $close_count++;
        }
    }
    is($close_count, 0, 'max_connection_reqs: first 3 responses have no Connection: close');

    if (defined $parts[3]) {
        like($parts[3], qr/Connection: close/i, 'max_connection_reqs: 4th response has Connection: close');
    } else {
        pass('max_connection_reqs: 4th response has Connection: close (implicit)');
    }
}

#######################################################################
# Section 6: Expect header edge cases
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Expect: 100\r\n" .
        "Content-Length: 5\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr/HTTP\/1\.1 417/, 'Expect: 100 (incomplete): rejected with 417');
}

{
    my $cv = AE::cv;
    my $got_continue = 0;
    my $full_response = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $main_port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );

    $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nExpect: 100-Continue\r\nContent-Length: 5\r\nConnection: close\r\n\r\n");

    $h->on_read(sub {
        my $data = $h->rbuf;
        $h->rbuf = '';
        $full_response .= $data;

        if (!$got_continue && $data =~ /100 Continue/i) {
            $got_continue = 1;
            $h->push_write("hello");
        }
        if ($full_response =~ /body_len=\d+/) {
            $cv->send;
        }
    });

    my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    like($full_response, qr/100 Continue/i, 'Expect: 100-Continue (mixed case): got continue');
    like($full_response, qr/200 OK/, 'Expect: 100-Continue (mixed case): got 200 OK');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Expect: something-else\r\n" .
        "Content-Length: 5\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr/HTTP\/1\.1 417/, 'Expect: unknown value: rejected with 417');
}

#######################################################################
# Section 7: Transfer-Encoding is undefined for HTTP/1.0 and is rejected;
# honouring Content-Length instead would be the TE.CL smuggling half behind
# an intermediary that honours Transfer-Encoding.
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.0\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 5\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr/HTTP\/1\.0 200/, 'HTTP/1.0 with CL: accepted');
    like($response, qr/body_len=5/, 'HTTP/1.0 with CL: body received');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.0\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Content-Length: 5\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr{HTTP/1\.0 400},
        'HTTP/1.0 + TE + CL: rejected, not silently CL-framed');
    like($response, qr/Transfer-Encoding not allowed/i,
        'HTTP/1.0 + TE + CL: error names the reason');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.0\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr{HTTP/1\.0 400}, 'HTTP/1.0 + TE only: rejected');
    like($response, qr/Transfer-Encoding not allowed/i,
        'HTTP/1.0 + TE only: error message');
}

#######################################################################
# Section 8: Large number of chunks (stress test chunk counting)
#######################################################################

{
    my $chunked_body = '';
    for my $i (1..500) {
        $chunked_body .= "1\r\nX\r\n";
    }
    $chunked_body .= "0\r\n\r\n";

    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        $chunked_body,
        10 * TIMEOUT_MULT
    );
    like($response, qr/HTTP\/1\.1 200/, '500 chunks: accepted');
    like($response, qr/body_len=500/, '500 chunks: body length correct');
}

#######################################################################
# Section 9: Trailer headers in chunked encoding
#######################################################################

{
    my $chunked_body = "5\r\nhello\r\n0\r\nX-Trailer: value\r\n\r\n";
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        $chunked_body
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunked with trailer: accepted');
    like($response, qr/body_len=5/, 'Chunked with trailer: body correct');
}

{
    my $chunked_body = "5\r\nhello\r\n0\r\nX-Trailer1: v1\r\nX-Trailer2: v2\r\n\r\n";
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        $chunked_body
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunked with multiple trailers: accepted');
}

#######################################################################
# Section 10: Transfer-Encoding case variations
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "transfer-encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE lowercase: accepted');
    like($response, qr/body_len=5/, 'TE lowercase: body correct');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "TRANSFER-ENCODING: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE uppercase: accepted');
    like($response, qr/body_len=5/, 'TE uppercase: body correct');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: CHUNKED\r\n" .
        "Connection: close\r\n\r\n" .
        "5\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE value CHUNKED: accepted');
    like($response, qr/body_len=5/, 'TE value CHUNKED: body correct');
}

#######################################################################
# Section 11: Chunked hex digit case variations
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "a\r\n0123456789\r\n0\r\n\r\n"  # a = 10
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk size lowercase hex: accepted');
    like($response, qr/body_len=10/, 'Chunk size lowercase hex: correct length');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "A\r\n0123456789\r\n0\r\n\r\n"  # A = 10
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk size uppercase hex: accepted');
    like($response, qr/body_len=10/, 'Chunk size uppercase hex: correct length');
}

{
    my $body = 'x' x 31;
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "1F\r\n${body}\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk size mixed hex 1F: accepted');
    like($response, qr/body_len=31/, 'Chunk size mixed hex 1F: correct length');
}

#######################################################################
# Section 12: Chunk extension handling
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5;ext=value\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk with extension: accepted');
    like($response, qr/body_len=5/, 'Chunk with extension: body correct');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "5;foo=bar;baz\r\nhello\r\n0\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Chunk with multiple extensions: accepted');
    like($response, qr/body_len=5/, 'Chunk with multiple extensions: body correct');
}

#######################################################################
# Section 13: URI length boundaries (MAX_URI_LEN is 8192)
#######################################################################

{
    my $long_path = '/test/' . ('x' x 7990);
    my $response = raw_request($main_port,
        "GET $long_path HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Long URI (8000 bytes): accepted');
}

{
    my $too_long_path = '/test/' . ('x' x 8500);
    my $response = raw_request($main_port,
        "GET $too_long_path HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 414/, 'Too long URI (8500 bytes): rejected with 414');
}

#######################################################################
# Section 14: Content-Length duplicates
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 5\r\n" .
        "Content-Length: 5\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr/HTTP\/1\.1 200/, 'Duplicate identical CL: accepted');
    like($response, qr/body_len=5/, 'Duplicate identical CL: body correct');
}

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 5\r\n" .
        "Content-Length: 10\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr/HTTP\/1\.1 400/, 'Duplicate conflicting CL: rejected with 400');
}

#######################################################################
# Section 15: Transfer-Encoding: identity
#######################################################################

{
    my $response = raw_request($main_port,
        "POST /test HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: identity\r\n" .
        "Content-Length: 5\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    like($response, qr/HTTP\/1\.1 200/, 'TE: identity with CL: accepted');
    like($response, qr/body_len=5/, 'TE: identity with CL: body correct');
}

#######################################################################
# Section 16: 204 via start_streaming - writes must be discarded
#######################################################################

{
    my ($socket16, $port16) = get_listen_socket();
    my $feer16 = Feersum->new_instance();
    $feer16->use_socket($socket16);
    $feer16->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(204, ['X-Test' => 'streaming-204']);
        $w->write("SHOULD-NOT-APPEAR");
        $w->close();
    });

    my $response = raw_request($port16,
        "GET /204 HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 204/, '204 streaming: got 204 status');
    unlike($response, qr/SHOULD-NOT-APPEAR/, '204 streaming: body write discarded');
    unlike($response, qr/Transfer-Encoding/i, '204 streaming: no chunked framing');

    $feer16->unlisten();
}

#######################################################################
# Section 17: max_h2_concurrent_streams clamping
#######################################################################

SKIP: {
    my $feer17 = Feersum->new_instance();
    skip 'H2 not compiled in', 3 unless $feer17->has_h2();

    is($feer17->max_h2_concurrent_streams(5000), 100,
        'h2 streams: clamped to compile-time ceiling (100)');
    is($feer17->max_h2_concurrent_streams(0), 1,
        'h2 streams: values below 1 clamped to 1');
    is($feer17->max_h2_concurrent_streams(50), 50,
        'h2 streams: in-range value accepted');
}

#######################################################################
# Section 18: native getter contracts on a body-less request
#######################################################################

{
    my ($socket18, $port18) = get_listen_socket();
    my $feer18 = Feersum->new_instance();
    $feer18->use_socket($socket18);

    my %cap;
    $feer18->request_handler(sub {
        my $r = shift;
        %cap = (
            input    => $r->input,
            trailers => $r->trailers,
            http11   => $r->is_http11,
            # psgix.io is only added for PSGI handlers; native handlers use
            # $r->io() instead (documented in Feersum / Feersum::Connection)
            has_psgix_io => exists $r->env->{'psgix.io'},
        );
        $r->send_response(200, ['Content-Type' => 'text/plain'], \"ok");
    });

    my $response = raw_request($port18,
        "GET /x HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    like($response, qr/HTTP\/1\.1 200/, 'native getters: request served');
    ok(!defined $cap{input}, 'native input() undef without a body');
    ok(!defined $cap{trailers}, 'native trailers() undef without trailers');
    ok($cap{http11}, 'native is_http11 true for HTTP/1.1');
    ok(!$cap{has_psgix_io}, 'native env() lacks psgix.io (use io() instead)');

    $feer18->unlisten();
}

#######################################################################
# Section 19: set_psgix_io / get_psgix_io toggle the env key
#######################################################################

{
    my ($socket19, $port19) = get_listen_socket();
    my $feer19 = Feersum->new_instance();
    $feer19->use_socket($socket19);

    is($feer19->get_psgix_io, 1, 'psgix_io: enabled by default');

    my $had_io;
    $feer19->psgi_request_handler(sub {
        my $env = shift;
        $had_io = exists $env->{'psgix.io'};
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });

    $feer19->set_psgix_io(0);
    is($feer19->get_psgix_io, 0, 'psgix_io: disabled via setter');
    my $r1 = raw_request($port19,
        "GET /a HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    like($r1, qr/HTTP\/1\.1 200/, 'psgix_io off: request served');
    ok(!$had_io, 'psgix_io off: env lacks psgix.io');

    $feer19->set_psgix_io(1);
    raw_request($port19,
        "GET /b HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    ok($had_io, 'psgix_io on: env has psgix.io');

    $feer19->unlisten();
}
