#!/usr/bin/env perl
use strict;
use warnings;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't';
use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

# Test MAX_BODY_LEN default and runtime override

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

my $request_handled = 0;
$feer->request_handler(sub {
    my $r = shift;
    $request_handled++;
    $r->send_response(200, ['Content-Type' => 'text/plain'], ['OK']);
});

# Helper to send request and get response status
sub get_status {
    my ($headers, $body) = @_;
    my $cv = AE::cv;
    my $response = '';
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );
    $h->push_write($headers . ($body || ''));
    $h->on_read(sub {
        $response .= $h->rbuf;
        $h->rbuf = '';
    });
    my $timer = AE::timer 5 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;
    if ($response =~ /HTTP\/1\.[01] (\d+)/) {
        return $1;
    }
    return '000';
}

# 1. Test default limit (64MB)
# We won't actually send 64MB in a unit test, but we can check Content-Length
# header rejection which happens early.
{
    $request_handled = 0;
    # 64MB + 1 byte
    my $too_big = 64 * 1024 * 1024 + 1;
    my $status = get_status("POST / HTTP/1.1
Host: localhost
Content-Length: $too_big
Connection: close

");
    is $status, '413', '64MB + 1 byte rejected with 413 (default limit)';
    is $request_handled, 0, 'request handler not called for oversized request';
}

# 2. Test runtime override
{
    $feer->max_body_len(1024); # 1KB limit
    $request_handled = 0;
    my $status = get_status("POST / HTTP/1.1
Host: localhost
Content-Length: 2048
Connection: close

");
    is $status, '413', '2KB rejected with 413 (override to 1KB)';
    is $request_handled, 0, 'request handler not called';

    # Under the new limit
    $request_handled = 0;
    my $body = "x" x 512;
    $status = get_status("POST / HTTP/1.1
Host: localhost
Content-Length: 512
Connection: close

", $body);
    is $status, '200', '512 bytes accepted (under 1KB limit)';
    is $request_handled, 1, 'request handler called';
}

# 3. Test reset to default (0)
{
    $feer->max_body_len(0);
    $request_handled = 0;
    my $too_big = 64 * 1024 * 1024 + 1;
    my $status = get_status("POST / HTTP/1.1
Host: localhost
Content-Length: $too_big
Connection: close

");
    is $status, '413', '64MB + 1 byte rejected after reset to default';
}

# 4. Negative values must croak, not wrap to a huge unsigned limit
{
    my $before = $feer->max_body_len;
    eval { $feer->max_body_len(-1) };
    like $@, qr/max_body_len must be non-negative/, 'negative max_body_len croaks';
    is $feer->max_body_len, $before, 'max_body_len unchanged after rejected set';

    # max_read_buf shares the same setter shape; guard it here too
    my $rb = $feer->max_read_buf;
    eval { $feer->max_read_buf(-1) };
    like $@, qr/max_read_buf must be non-negative/, 'negative max_read_buf croaks';
    is $feer->max_read_buf, $rb, 'max_read_buf unchanged after rejected set';
}

# 5. max_read_buf enforcement (plain socket): an unterminated header run past
# the cap is rejected with 431 (the header-accumulation DoS guard in
# try_conn_read; the TLS twin is covered by t/32c). A declared body larger
# than max_read_buf but within max_body_len is NOT capped here - that is
# governed by max_body_len.
{
    $feer->max_read_buf(16 * 1024);
    $feer->max_body_len(8 * 1024 * 1024);
    $request_handled = 0;
    my $huge = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Pad: "
        . ("A" x (64 * 1024)) . "\r\n\r\n";
    my $status = get_status($huge);
    is $status, '431',
        'plain: oversized headers rejected via max_read_buf (431: fields, not payload)';
    is $request_handled, 0, 'plain: handler not called for oversized headers';

    my $body = "P" x (64 * 1024);   # > max_read_buf, < max_body_len
    $status = get_status("POST / HTTP/1.1\r\nHost: localhost\r\n"
        . "Content-Length: " . length($body) . "\r\nConnection: close\r\n\r\n"
        . $body);
    is $status, '200', 'plain: large body within max_body_len accepted';
    $feer->max_read_buf(0);         # reset to default for any later sections
}

done_testing;
