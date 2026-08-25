#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 58;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

#######################################################################
# Test connection methods: is_http11, is_keepalive, protocol, headers
# normalization styles, and other accessors
#######################################################################

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);  # Enable keepalive for testing

# Test HTTP/1.1 request
{
    my $cv = AE::cv;
    my %captured;

    $feer->request_handler(sub {
        my $r = shift;
        $captured{is_http11} = $r->is_http11;
        $captured{is_keepalive} = $r->is_keepalive;
        $captured{protocol} = $r->protocol;
        $captured{method} = $r->method;
        $captured{uri} = $r->uri;
        $captured{path} = $r->path;
        $captured{query} = $r->query;
        $captured{fileno} = $r->fileno;
        $captured{remote_address} = $r->remote_address;
        $captured{remote_port} = $r->remote_port;
        $captured{content_length} = $r->content_length;

        # Test headers with different normalization styles
        $captured{headers_raw} = $r->headers(0);  # no normalization
        $captured{headers_locase} = $r->headers(Feersum::HEADER_NORM_LOCASE);
        $captured{headers_upcase} = $r->headers(Feersum::HEADER_NORM_UPCASE);
        $captured{headers_locase_dash} = $r->headers(Feersum::HEADER_NORM_LOCASE_DASH);
        $captured{headers_upcase_dash} = $r->headers(Feersum::HEADER_NORM_UPCASE_DASH);

        # Test single header lookup
        $captured{host_header} = $r->header('host');
        $captured{ua_header} = $r->header('user-agent');

        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    my $h = simple_client GET => '/test/path?foo=bar&baz=1',
        headers => { 'X-Custom' => 'test-value' },
        keepalive => 1,
        sub { };

    $cv->recv;

    # Verify captured values
    ok $captured{is_http11}, 'is_http11 returns true for HTTP/1.1';
    ok $captured{is_keepalive}, 'is_keepalive returns true for HTTP/1.1 default';
    is $captured{protocol}, 'HTTP/1.1', 'protocol returns HTTP/1.1';
    is $captured{method}, 'GET', 'method returns GET';
    is $captured{uri}, '/test/path?foo=bar&baz=1', 'uri returns full URI';
    is $captured{path}, '/test/path', 'path returns decoded path';
    is $captured{query}, 'foo=bar&baz=1', 'query returns query string';
    ok $captured{fileno} > 0, 'fileno returns positive fd';
    is $captured{remote_address}, '127.0.0.1', 'remote_address returns 127.0.0.1';
    ok $captured{remote_port} =~ /^\d+$/, 'remote_port is numeric';
    is $captured{content_length}, 0, 'content_length is 0 for GET';

    # Check headers hash structure (headers() returns a hash ref, not array)
    ok ref($captured{headers_raw}) eq 'HASH', 'headers returns hash ref';
    ok keys %{$captured{headers_raw}} >= 1, 'headers has at least one header';

    # Check header normalization - find Host header in each style
    my %raw = %{$captured{headers_raw}};
    my %locase = %{$captured{headers_locase}};
    my %upcase = %{$captured{headers_upcase}};
    my %locase_dash = %{$captured{headers_locase_dash}};
    my %upcase_dash = %{$captured{headers_upcase_dash}};

    ok exists $raw{Host} || exists $raw{host}, 'raw headers contain Host';
    ok exists $locase{host}, 'locase normalized to "host"';
    ok exists $upcase{HOST}, 'upcase normalized to "HOST"';
    ok exists $locase_dash{host}, 'locase_dash normalized to "host"';
    ok exists $upcase_dash{HOST}, 'upcase_dash normalized to "HOST"';

    # Check custom header normalization
    ok exists $locase{'x-custom'}, 'custom header locase: x-custom';
    ok exists $upcase{'X-CUSTOM'}, 'custom header upcase: X-CUSTOM';
    ok exists $locase_dash{'x_custom'}, 'custom header locase_dash: x_custom';
    ok exists $upcase_dash{'X_CUSTOM'}, 'custom header upcase_dash: X_CUSTOM';

    # Single header lookup
    like $captured{host_header}, qr/localhost/, 'header("host") returns host value';
    is $captured{ua_header}, 'FeersumSimpleClient/1.0', 'header("user-agent") works';
}

# Test HTTP/1.0 request with Connection: close
{
    my $cv = AE::cv;
    my %captured;

    $feer->request_handler(sub {
        my $r = shift;
        $captured{is_http11} = $r->is_http11;
        $captured{is_keepalive} = $r->is_keepalive;
        $captured{protocol} = $r->protocol;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    # Send raw HTTP/1.0 request
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write("GET /test HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok !$captured{is_http11}, 'is_http11 returns false for HTTP/1.0';
    ok !$captured{is_keepalive}, 'is_keepalive returns false for HTTP/1.0 + Connection: close';
    is $captured{protocol}, 'HTTP/1.0', 'protocol returns HTTP/1.0';
}

# Test HTTP/1.1 with Connection: close
{
    my $cv = AE::cv;
    my %captured;

    $feer->request_handler(sub {
        my $r = shift;
        $captured{is_http11} = $r->is_http11;
        $captured{is_keepalive} = $r->is_keepalive;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write("GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok $captured{is_http11}, 'is_http11 returns true for HTTP/1.1';
    ok !$captured{is_keepalive}, 'is_keepalive returns false with Connection: close';
}

# Test HTTP/1.0 with Connection: keep-alive
{
    my $cv = AE::cv;
    my %captured;

    $feer->request_handler(sub {
        my $r = shift;
        $captured{is_http11} = $r->is_http11;
        $captured{is_keepalive} = $r->is_keepalive;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write("GET /test HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n");
    $h->on_read(sub { });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    ok !$captured{is_http11}, 'is_http11 returns false for HTTP/1.0';
    ok $captured{is_keepalive}, 'is_keepalive returns true for HTTP/1.0 + Connection: keep-alive';
}

# Test POST with body
{
    my $cv = AE::cv;
    my %captured;
    my $body_content = 'test=data&more=stuff';

    $feer->request_handler(sub {
        my $r = shift;
        $captured{method} = $r->method;
        $captured{content_length} = $r->content_length;
        $captured{content_type} = $r->header('content-type');

        my $input = $r->input;
        ok defined $input, 'input handle defined for POST';

        my $body = '';
        $input->read($body, $captured{content_length});
        $captured{body} = $body;
        $input->close;

        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    my $h = simple_client POST => '/submit',
        body => $body_content,
        headers => { 'Content-Type' => 'application/x-www-form-urlencoded' },
        sub { };

    $cv->recv;

    is $captured{method}, 'POST', 'method returns POST';
    is $captured{content_length}, length($body_content), 'content_length matches body';
    is $captured{content_type}, 'application/x-www-form-urlencoded', 'content-type header';
    is $captured{body}, $body_content, 'body content matches';
}

# Test metrics: active_conns and total_requests
{
    my $active = $feer->active_conns;
    ok defined $active, 'active_conns returns a value';
    ok $active >= 0, 'active_conns is non-negative';

    my $total = $feer->total_requests;
    ok defined $total, 'total_requests returns a value';
    ok $total >= 5, 'total_requests counted our requests (at least 5)';
}

# Test header() with duplicate headers (multi-value joining)
{
    my $cv = AE::cv;
    my %captured;

    $feer->request_handler(sub {
        my $r = shift;
        $captured{cookie} = $r->header('cookie');
        $captured{accept} = $r->header('accept');
        $captured{headers} = $r->headers(Feersum::HEADER_NORM_LOCASE);
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    # Send duplicate Cookie and Accept headers
    $h->push_write(
        "GET /dup HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Cookie: session=abc123\r\n" .
        "Cookie: pref=dark\r\n" .
        "Accept: text/html\r\n" .
        "Accept: application/json\r\n" .
        "Connection: close\r\n\r\n"
    );
    $h->on_read(sub { });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    # Cookie uses "; " separator per RFC 9113 section 8.2.3
    is $captured{cookie}, 'session=abc123; pref=dark',
        'header("cookie") joins duplicates with "; "';
    # Non-cookie headers use ", " separator per RFC 7230
    is $captured{accept}, 'text/html, application/json',
        'header("accept") joins duplicates with ", "';
    # headers() hash should also join correctly
    is $captured{headers}{cookie}, 'session=abc123; pref=dark',
        'headers() cookie joined with "; "';
    is $captured{headers}{accept}, 'text/html, application/json',
        'headers() accept joined with ", "';
}

# Test header() case-insensitivity
{
    my $cv = AE::cv;
    my %captured;

    $feer->request_handler(sub {
        my $r = shift;
        $captured{lc} = $r->header('x-custom');
        $captured{uc} = $r->header('X-CUSTOM');
        $captured{mc} = $r->header('X-Custom');
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
        $cv->send;
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
    );
    $h->push_write(
        "GET /ci HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "X-Custom: hello\r\n" .
        "Connection: close\r\n\r\n"
    );
    $h->on_read(sub { });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    is $captured{lc}, 'hello', 'header() case-insensitive: lowercase lookup';
    is $captured{uc}, 'hello', 'header() case-insensitive: uppercase lookup';
    is $captured{mc}, 'hello', 'header() case-insensitive: mixed case lookup';
}

# Test streaming 204 response has no Transfer-Encoding: chunked
{
    my $cv = AE::cv;
    my $response = '';

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(204, []);
        $w->close();
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
        on_eof   => sub { $cv->send },
    );
    # No Connection: close - keepalive preserved (204 has no body per RFC 7230 section 3.3.3)
    $h->push_write("GET /s204 HTTP/1.1\r\nHost: localhost\r\n\r\n");
    $h->on_read(sub { $response .= $_[0]{rbuf}; $_[0]{rbuf} = '' });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    like $response, qr{^HTTP/1\.1 204 }, 'streaming 204 - status line correct';
    unlike $response, qr/Transfer-Encoding/i,
        'streaming 204 - no Transfer-Encoding header (RFC 7230 section 3.3.1)';
    unlike $response, qr/chunked/i,
        'streaming 204 - no chunked encoding';
    # RFC 7230 section 3.3.3: 204 has no body, so keepalive is preserved (no Connection: close)
    unlike $response, qr/Connection: close/i,
        'streaming 204 - keepalive preserved (no body per RFC 7230 section 3.3.3)';
}

# Test 204 send_response discards app-provided body (RFC 7230 section 3.3)
{
    my $cv = AE::cv;
    my $response = '';

    $feer->request_handler(sub {
        my $r = shift;
        # App mistakenly provides a body for 204 - server must discard it
        $r->send_response(204, ['Content-Type' => 'text/plain'], \"should be discarded");
    });

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
        on_eof   => sub { $cv->send },
    );
    $h->push_write("GET /204body HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { $response .= $_[0]{rbuf}; $_[0]{rbuf} = '' });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    like $response, qr{^HTTP/1\.1 204 }, '204 body discard - status 204';
    unlike $response, qr/should be discarded/,
        '204 body discard - app body not sent (RFC 7230 section 3.3)';
}

pass 'all connection method tests completed';
