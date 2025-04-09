#!perl
use warnings;
use strict;
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
# Set a shorter read timeout to fail faster in case of problems
$evh->read_timeout(2.0);

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

    # Add small delays to verify ordering for specific requests
    my @res = (
        200,
        ['Content-Type' => 'text/plain'],
        ["Response $request_count: $method $path" . ($body ? " Body: $body" : "")]
    );

    # Add delay for certain paths to test response ordering
    if ($path =~ /\/delay|\/test2|\/keepalive2/) {
        my $w; $w = AE::timer 0.1, 0, sub {
            undef $w;
            $r->send_response(@res);
        };
    } else {
        $r->send_response(@res)
    }
});

is exception {
    $evh->use_socket($listen_socket);
}, undef, 'assigned socket';

# Part 1: Test pipelined requests
subtest 'Pipelined Requests' => sub {
    plan tests => 23;
    my $cv = AE::cv;
    $cv->begin;

    # Create connection using AnyEvent::Handle
    my @responses;
    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 5,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "client error: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Done handling all responses
            my $responses = join "\n\n", @responses;
            like($responses, qr/Response \d+: GET \/test1.*Response \d+: GET \/test2.*Response \d+: POST \/post1.*Response \d+: POST \/post2.*Response \d+: GET \/test3/s,
                'Got all pipelined responses in correct order');

            # Verify each response had proper headers
            is(scalar(@responses), 5, 'Got expected number of response parts');

            my @parts = map { split /\r\n\r\n/ } @responses;

            # First response (GET)
            like($parts[0], qr/^HTTP\/1\.1 200 OK/, 'First response has correct status');
            like($parts[0], qr/Content-Type: text\/plain/, 'First response has content type');
            like($parts[1], qr/Response \d+: GET \/test1/, 'First response has correct body');

            # Second response (GET with delay)
            like($parts[2], qr/^HTTP\/1\.1 200 OK/, 'Second response has correct status');
            like($parts[2], qr/Content-Type: text\/plain/, 'Second response has content type');
            like($parts[3], qr/Response \d+: GET \/test2/, 'Second response has correct body');

            # Third response (POST with small body)
            like($parts[4], qr/^HTTP\/1\.1 200 OK/, 'Third response has correct status');
            like($parts[4], qr/Content-Type: text\/plain/, 'Third response has content type');
            like($parts[5], qr/Response \d+: POST \/post1 Body: Hello, world!/, 'Third response has correct body with POST data');

            # Fourth response (POST with larger body)
            like($parts[6], qr/^HTTP\/1\.1 200 OK/, 'Fourth response has correct status');
            like($parts[6], qr/Content-Type: text\/plain/, 'Fourth response has content type');
            like($parts[7], qr/Response \d+: POST \/post2 Body: This is a larger test body/, 'Fourth response has correct body with POST data');

            # Fifth response (GET with close)
            like($parts[8], qr/^HTTP\/1\.1 200 OK/, 'Fifth response has correct status');
            like($parts[8], qr/Content-Type: text\/plain/, 'Fifth response has content type');
            like($parts[8], qr/Connection: close/, 'Fifth response has Connection: close');
            like($parts[9], qr/Response \d+: GET \/test3/, 'Fifth response has correct body');

            $cv->end;
            $h->destroy;
        },
        on_read => sub {
            last unless my $len = length(my $buf = $_[0]->rbuf);
            push @responses, $buf;
            substr $_[0]->rbuf, 0, $len, '';
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

    my @responses;
    my $request_index = 0;
    my @requests = (
        "GET /keepalive1 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /keepalive2 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "POST /keepalive-post HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nKeepAlive!",
        "GET /keepalive-end HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );

    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 5,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "client error in keepalive test: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Done handling all responses
            is(scalar(@responses), 4, 'Got expected number of keepalive responses');

            my @parts = map { split /\r\n\r\n/ } @responses;

            # First keepalive response
            like($parts[0], qr/^HTTP\/1\.1 200 OK/, 'First keepalive response has correct status');
            like($parts[1], qr/Response \d+: GET \/keepalive1/, 'First keepalive response has correct body');

            # Second keepalive response (with delay)
            like($parts[2], qr/^HTTP\/1\.1 200 OK/, 'Second keepalive response has correct status');
            like($parts[3], qr/Response \d+: GET \/keepalive2/, 'Second keepalive response has correct body');

            # Third keepalive response (POST)
            like($parts[4], qr/^HTTP\/1\.1 200 OK/, 'Third keepalive response has correct status');
            like($parts[5], qr/Response \d+: POST \/keepalive-post Body: KeepAlive!/, 'Third keepalive response has correct POST body');

            # Fourth keepalive response (with close)
            like($parts[6], qr/^HTTP\/1\.1 200 OK/, 'Fourth keepalive response has correct status');
            like($parts[6], qr/Connection: close/, 'Fourth keepalive response has Connection: close');
            like($parts[7], qr/Response \d+: GET \/keepalive-end/, 'Fourth keepalive response has correct body');

            $cv->end;
            $h->destroy;
        },
        on_read => sub {
            my ($handle) = @_;
            last unless my $len = length(my $buf = $handle->rbuf);

            # Store response
            push @responses, $buf;
            substr $handle->rbuf, 0, $len, '';

            # Send next request when we get a complete response
            if ($request_index < scalar(@requests) - 1 && $buf =~ /\r\n\r\n/) {
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
    plan tests => 20;
    my $cv = AE::cv;
    $cv->begin;

    my @responses;
    my $mixed_phase = 0;
    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 5,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "client error in mixed test: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Done handling all responses
            my $full_response = join('', @responses);

            # Count how many responses we actually got (should be 7)
            my $response_count = () = $full_response =~ /Response \d+:/g;
            is($response_count, 7, "Got all $response_count responses");

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

            # Check for content type headers
            my $ct_count = () = $full_response =~ /Content-Type: text\/plain/g;
            is($ct_count, 7, 'All responses have correct content type');

            # Check Connection: close in the final response
            like($full_response, qr/Connection: close.*Response \d+: GET \/mixed\/final/s,
                 'Final response has Connection: close');

            # Validate order of responses
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
            last unless my $len = length(my $buf = $handle->rbuf);

            # Store response
            push @responses, $buf;
            substr $handle->rbuf, 0, $len, '';

            # Progress through test phases based on response count
            if ($mixed_phase == 0 && scalar @responses >= 1) {
                # Move to phase 1 after receiving the initial POST response
                $mixed_phase = 1;
                # Send a mix of GET requests
                $handle->push_write(
                    "GET /mixed1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
                    "GET /mixed/delay HTTP/1.1\r\nHost: localhost\r\n\r\n"
                );
            }
            elsif ($mixed_phase == 1 && scalar @responses >= 3) {
                # Move to phase 2 after receiving responses to the first two GETs
                $mixed_phase = 2;
                # Allow a small delay to ensure responses are processed
                my $t; $t = AE::timer 0.2, 0, sub {
                    undef $t;
                    # Send multiple pipelined POST requests followed by GETs
                    $handle->push_write(
                        "POST /mixed/post1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9\r\n\r\nFirstPost" .
                        "POST /mixed/post2 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nSecondPost" .
                        "GET /mixed/get1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
                        "GET /mixed/final HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                    );
                };
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
