#!/usr/bin/env perl
# An app returning without reading a Content-Length body must not leave those
# bytes to be parsed as the next pipelined request, and $input->read() must
# not read past Content-Length into pipelined data.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

BEGIN {
    plan skip_all => 'not applicable on win32'
        if $^O eq 'MSWin32';
}

plan tests => 23;

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

# Track what the handler sees
my @requests_received;
my $handler_mode = 'read_body';  # 'read_body', 'skip_body', 'over_read'

$feer->request_handler(sub {
    my $r = shift;
    my $method = $r->method;
    my $path   = $r->path;
    my $cl     = $r->content_length || 0;
    my $body   = '';

    if ($handler_mode eq 'read_body' && $cl > 0) {
        my $input = $r->input;
        $input->read($body, $cl) if $input;
    }
    elsif ($handler_mode eq 'over_read' && $cl > 0) {
        my $input = $r->input;
        $input->read($body, $cl + 200) if $input;
    }
    # 'skip_body' - intentionally don't read

    push @requests_received, {
        method   => $method,
        path     => $path,
        body     => $body,
        body_len => length($body),
        cl       => $cl,
    };
    $r->send_response(200, ['Content-Type' => 'text/plain'],
        \"OK: $method $path");
});

sub raw_request {
    my ($request, $timeout) = @_;
    $timeout ||= 3;
    @requests_received = ();

    my $cv = AE::cv;
    my $response = '';

    my $h = AnyEvent::Handle->new(
        connect  => ['127.0.0.1', $port],
        on_error => sub { $cv->send; },
        on_eof   => sub { $cv->send; },
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

# =========================================================================
# Test 1: Normal POST with body + pipelined GET (regression test)
# =========================================================================
{
    note "Normal POST + pipelined GET (regression)";
    $handler_mode = 'read_body';

    my $body = "hello body here!";
    my $response = raw_request(
        "POST /first HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: " . length($body) . "\r\n" .
        "\r\n" .
        $body .
        "GET /second HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    my @responses = ($response =~ /HTTP\/1\.1 200/g);
    is scalar(@responses), 2, "both requests served (got 2 responses)";
    is scalar(@requests_received), 2, "handler called twice";
    is $requests_received[0]{path}, '/first',  "first request path";
    is $requests_received[0]{body}, $body,      "first request body read correctly";
    is $requests_received[1]{path}, '/second',  "second request path (pipelined)";
}

# =========================================================================
# Test 2: POST early return (no body read) + pipelined GET
#         Body is drained, pipelined GET IS served.
# =========================================================================
{
    note "POST early return (skip body) + pipelined GET";
    $handler_mode = 'skip_body';

    my $body = "X" x 50;
    my $response = raw_request(
        "POST /early HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: " . length($body) . "\r\n" .
        "\r\n" .
        $body .
        "GET /should-not-be-served HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    my @responses = ($response =~ /HTTP\/1\.1 200/g);
    is scalar(@responses), 2, "both requests served (body drained)";
    is scalar(@requests_received), 2, "handler called twice";
    is $requests_received[0]{path}, '/early', "early-return request path";
    is $requests_received[0]{body}, '',        "body was not read";
}

# =========================================================================
# Test 3: POST over-read attempt - read() should stop at Content-Length
# =========================================================================
{
    note "POST over-read attempt";
    $handler_mode = 'over_read';

    my $body = "REAL_BODY_DATA";
    my $response = raw_request(
        "POST /overread HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: " . length($body) . "\r\n" .
        "Connection: close\r\n" .
        "\r\n" .
        $body .
        "GET /secret HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "\r\n"
    );

    is scalar(@requests_received), 1, "handler called once";
    is $requests_received[0]{body}, $body,
        "read() returned exactly Content-Length bytes";
    unlike $requests_received[0]{body}, qr/secret/,
        "pipelined request data not leaked into body";
}

# =========================================================================
# Test 4: Normal chunked POST + pipelined GET (regression test)
# =========================================================================
{
    note "Normal chunked POST + pipelined GET (regression)";
    $handler_mode = 'read_body';

    my $body = "chunked body!";  # 13 bytes = 0xd
    my $response = raw_request(
        "POST /chunked-first HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "\r\n" .
        sprintf("%x\r\n%s\r\n0\r\n\r\n", length($body), $body) .
        "GET /chunked-second HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    my @responses = ($response =~ /HTTP\/1\.1 200/g);
    is scalar(@responses), 2, "chunked: both requests served (got 2 responses)";
    is scalar(@requests_received), 2, "chunked: handler called twice";
    is $requests_received[0]{path}, '/chunked-first',  "chunked: first request path";
    is $requests_received[0]{body}, $body, "chunked: body read correctly";
    is $requests_received[1]{path}, '/chunked-second',
        "chunked: second request path (pipelined)";
}

# =========================================================================
# Test 5: Chunked POST early return (no body read) + pipelined GET
#         Connection should close - pipelined GET should NOT be served.
# =========================================================================
{
    note "Chunked POST early return (skip body) + pipelined GET";
    $handler_mode = 'skip_body';

    my $body = "Y" x 50;
    my $response = raw_request(
        "POST /chunked-early HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "\r\n" .
        sprintf("%x\r\n%s\r\n0\r\n\r\n", length($body), $body) .
        "GET /chunked-should-not-serve HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    my @responses = ($response =~ /HTTP\/1\.1 200/g);
    is scalar(@responses), 2,
        "chunked skip: both requests served (body drained)";
    is scalar(@requests_received), 2, "chunked skip: handler called twice";
    is $requests_received[0]{path}, '/chunked-early',
        "chunked skip: early-return request path";
    is $requests_received[0]{body}, '', "chunked skip: body was not read";
}

pass "all pipeline body tests completed";
