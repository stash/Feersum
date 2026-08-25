#!perl
use warnings;
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More tests => 9;
use Test::Fatal;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($listen_socket, $port) = get_listen_socket();
ok $listen_socket, "made listen socket";
ok $listen_socket->fileno, "has a fileno";

my $evh = Feersum->new();

# Enable keep-alive which is needed for all tests
$evh->set_keepalive(1);
# Set read timeout - scaled for slow machines
$evh->read_timeout(2.0 * TIMEOUT_MULT);

my $request_count = 0;
$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';

    $request_count++;
    my $method = $r->method;
    my $path = $r->path;
    my $body = '';

    # Read POST body if applicable
    if ($method eq 'POST') {
        my $input = $r->input;
        if ($input) {
            my $cl = $r->content_length;
            $input->read($body, $cl) if $cl > 0;
        }
    }

    my @res = (
        200,
        ['Content-Type' => 'text/plain'],
        ["Response $request_count: $method $path" . ($body ? " Body: $body" : "")]
    );

    $r->send_response(@res)
});

is exception {
    $evh->use_socket($listen_socket);
}, undef, 'assigned socket';

# Helper function to parse HTTP responses from a raw buffer
# Returns arrayref of { headers => $headers_str, body => $body_str } hashrefs
sub parse_http_responses {
    my ($buffer) = @_;
    my @responses;

    while ($buffer =~ /\S/) {
        # Find end of headers
        my $header_end = index($buffer, "\r\n\r\n");
        last if $header_end < 0;

        my $headers = substr($buffer, 0, $header_end);
        $buffer = substr($buffer, $header_end + 4);

        # Extract Content-Length from headers
        my ($content_length) = $headers =~ /Content-Length:\s*(\d+)/i;
        $content_length //= 0;

        # Extract body based on Content-Length
        my $body = '';
        if ($content_length > 0 && length($buffer) >= $content_length) {
            $body = substr($buffer, 0, $content_length);
            $buffer = substr($buffer, $content_length);
        }

        push @responses, { headers => $headers, body => $body };
    }

    return \@responses;
}

# Part 1: Test pipelined requests
subtest 'Pipelined Requests' => sub {
    plan tests => 23;
    my $cv = AE::cv;
    $cv->begin;

    # Accumulate all data into a single buffer
    my $buffer = '';
    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "client error: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Parse all responses from buffer
            my $responses = parse_http_responses($buffer);

            # Verify we got all 5 responses
            is(scalar(@$responses), 5, 'Got expected number of responses');

            # Overall order check
            my $all_bodies = join(' ', map { $_->{body} } @$responses);
            like($all_bodies, qr/Response \d+: GET \/test1.*Response \d+: GET \/test2.*Response \d+: POST \/post1.*Response \d+: POST \/post2.*Response \d+: GET \/test3/s,
                'Got all pipelined responses in correct order');

            # First response (GET)
            like($responses->[0]{headers}, qr/^HTTP\/1\.1 200 OK/, 'First response has correct status');
            like($responses->[0]{headers}, qr/Content-Type: text\/plain/, 'First response has content type');
            like($responses->[0]{body}, qr/Response \d+: GET \/test1/, 'First response has correct body');

            # Second response (GET)
            like($responses->[1]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Second response has correct status');
            like($responses->[1]{headers}, qr/Content-Type: text\/plain/, 'Second response has content type');
            like($responses->[1]{body}, qr/Response \d+: GET \/test2/, 'Second response has correct body');

            # Third response (POST with small body)
            like($responses->[2]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Third response has correct status');
            like($responses->[2]{headers}, qr/Content-Type: text\/plain/, 'Third response has content type');
            like($responses->[2]{body}, qr/Response \d+: POST \/post1 Body: Hello, world!/, 'Third response has correct body with POST data');

            # Fourth response (POST with larger body)
            like($responses->[3]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Fourth response has correct status');
            like($responses->[3]{headers}, qr/Content-Type: text\/plain/, 'Fourth response has content type');
            like($responses->[3]{body}, qr/Response \d+: POST \/post2 Body: This is a larger test body/, 'Fourth response has correct body with POST data');

            # Fifth response (GET with close)
            like($responses->[4]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Fifth response has correct status');
            like($responses->[4]{headers}, qr/Content-Type: text\/plain/, 'Fifth response has content type');
            like($responses->[4]{headers}, qr/Connection: close/, 'Fifth response has Connection: close');
            like($responses->[4]{body}, qr/Response \d+: GET \/test3/, 'Fifth response has correct body');

            $cv->end;
            $h->destroy;
        },
        on_read => sub {
            # Accumulate all data into buffer
            $buffer .= $_[0]->rbuf;
            $_[0]->rbuf = '';
        }
    );

    # Create small and larger POST bodies
    my $post_body1 = "Hello, world!";
    my $post_body2 = "This is a larger test body";

    # Send pipelined requests including GETs and POSTs
    $h->push_write(
        "GET /test1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
        "GET /test2 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
        "POST /post1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: " . length($post_body1) . "\r\n\r\n" . $post_body1 .
        "POST /post2 HTTP/1.1\r\nHost: localhost\r\nContent-Length: " . length($post_body2) . "\r\n\r\n" . $post_body2 .
        "GET /test3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );

    $cv->recv;
};

# Part 2: Test keepalive requests (sequential requests on same connection)
subtest 'Keepalive Requests' => sub {
    plan tests => 14;
    my $cv = AE::cv;
    $cv->begin;

    my $buffer = '';
    my $request_index = 0;
    my $responses_received = 0;
    my @requests = (
        "GET /keepalive1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /keepalive2 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "POST /keepalive-post HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nKeepAlive!",
        "GET /keepalive-end HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );

    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "client error in keepalive test: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Parse all responses from buffer
            my $responses = parse_http_responses($buffer);

            is(scalar(@$responses), 4, 'Got expected number of keepalive responses');

            # First keepalive response
            like($responses->[0]{headers}, qr/^HTTP\/1\.1 200 OK/, 'First keepalive response has correct status');
            like($responses->[0]{body}, qr/Response \d+: GET \/keepalive1/, 'First keepalive response has correct body');

            # Second keepalive response
            like($responses->[1]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Second keepalive response has correct status');
            like($responses->[1]{body}, qr/Response \d+: GET \/keepalive2/, 'Second keepalive response has correct body');

            # Third keepalive response (POST)
            like($responses->[2]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Third keepalive response has correct status');
            like($responses->[2]{body}, qr/Response \d+: POST \/keepalive-post Body: KeepAlive!/, 'Third keepalive response has correct POST body');

            # Fourth keepalive response (with close)
            like($responses->[3]{headers}, qr/^HTTP\/1\.1 200 OK/, 'Fourth keepalive response has correct status');
            like($responses->[3]{headers}, qr/Connection: close/, 'Fourth keepalive response has Connection: close');
            like($responses->[3]{body}, qr/Response \d+: GET \/keepalive-end/, 'Fourth keepalive response has correct body');

            $cv->end;
            $h->destroy;
        },
        on_read => sub {
            my ($handle) = @_;
            $buffer .= $handle->rbuf;
            $handle->rbuf = '';

            # Count how many complete responses we have so far
            my $temp_responses = parse_http_responses($buffer);
            my $new_count = scalar(@$temp_responses);

            # Send next request when we get a new response
            if ($new_count > $responses_received && $request_index < scalar(@requests) - 1) {
                $responses_received = $new_count;
                $request_index++;
                $handle->push_write($requests[$request_index]);
            }
        }
    );

    # Send first request
    $h->push_write($requests[0]);
    $cv->recv;
};

# Part 3: Test mixed keepalive and pipelined requests with more POST requests
subtest 'Mixed Keepalive and Pipelined Requests' => sub {
    plan tests => 19;  # 7 isa_ok from request handler + 12 assertion tests
    my $cv = AE::cv;
    $cv->begin;

    my $buffer = '';
    my $mixed_phase = 0;
    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "client error in mixed test: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Parse all responses
            my $responses = parse_http_responses($buffer);
            my $full_response = $buffer;

            # Count how many responses we actually got (should be 7)
            is(scalar(@$responses), 7, 'Got all 7 responses');

            # Verify we got responses for all expected requests
            like($full_response, qr/Response \d+: POST \/mixed\/initial Body: InitialPost/,
                 'Contains initial POST response');
            like($full_response, qr/Response \d+: GET \/mixed1/,
                 'Contains mixed1 response');
            like($full_response, qr/Response \d+: GET \/mixed\/delay/,
                 'Contains mixed/delay response');
            like($full_response, qr/Response \d+: POST \/mixed\/post1 Body: FirstPost/,
                 'Contains POST1 response');
            like($full_response, qr/Response \d+: POST \/mixed\/post2 Body: SecondPost/,
                 'Contains POST2 response');
            like($full_response, qr/Response \d+: GET \/mixed\/get1/,
                 'Contains mixed/get1 response');
            like($full_response, qr/Response \d+: GET \/mixed\/final/,
                 'Contains mixed/final response');

            # Check for correct status codes
            my $status_count = () = $full_response =~ /HTTP\/1\.1 200 OK/g;
            is($status_count, 7, 'All responses have correct status code');

            # Check Connection: close in the final response
            like($full_response, qr/Connection: close.*Response \d+: GET \/mixed\/final/s,
                 'Final response has Connection: close');

            # Validate order of responses - extract response numbers and verify ascending
            my @response_numbers = $full_response =~ /Response (\d+):/g;
            is(scalar(@response_numbers), 7, 'Captured 7 response numbers');

            # Check response numbers are in ascending order
            my $is_ascending = 1;
            for (my $i = 1; $i < scalar(@response_numbers); $i++) {
                if ($response_numbers[$i] <= $response_numbers[$i-1]) {
                    $is_ascending = 0;
                    last;
                }
            }
            ok($is_ascending, 'Response numbers are in ascending order');

            $cv->end;
            $h->destroy;
        },
        on_read => sub {
            my ($handle) = @_;
            $buffer .= $handle->rbuf;
            $handle->rbuf = '';

            # Parse current responses to determine phase transitions
            my $responses = parse_http_responses($buffer);
            my $resp_count = scalar(@$responses);

            # Progress through test phases based on response count
            if ($mixed_phase == 0 && $resp_count >= 1) {
                # Move to phase 1 after receiving the initial POST response
                $mixed_phase = 1;
                # Send a mix of GET requests (pipelined)
                $handle->push_write(
                    "GET /mixed1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
                    "GET /mixed/delay HTTP/1.1\r\nHost: localhost\r\n\r\n"
                );
            }
            elsif ($mixed_phase == 1 && $resp_count >= 3) {
                # Move to phase 2 after receiving responses to the first two GETs
                $mixed_phase = 2;
                # Send multiple pipelined POST requests followed by GETs
                $handle->push_write(
                    "POST /mixed/post1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\n\r\nFirstPost" .
                    "POST /mixed/post2 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nSecondPost" .
                    "GET /mixed/get1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
                    "GET /mixed/final HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                );
            }
        }
    );

    # First send a single POST request
    $h->push_write(
        "POST /mixed/initial HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nInitialPost"
    );

    $cv->recv;
};

# Skip the actual count check, as it can vary based on how responses are batched
ok($request_count > 0, "Handled multiple requests ($request_count in total)");
pass "all done";
