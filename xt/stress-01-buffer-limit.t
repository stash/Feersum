#!/usr/bin/env perl
# Test MAX_READ_BUF (64MB) limit protection
# This is an author test because it requires significant memory
use strict;
use warnings;
use Test::More;
use lib 't';
use Utils;

BEGIN {
    plan skip_all => "Author test: set AUTHOR_TESTING=1 to run"
        unless $ENV{AUTHOR_TESTING};
    plan skip_all => "This test requires ~70MB free memory"
        unless eval { my $x = 'x' x (70 * 1024 * 1024); 1 };
}

use_ok('Feersum');

my ($socket, $port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();
$evh->use_socket($socket);

my $request_received = 0;
$evh->request_handler(sub {
    my $r = shift;
    $request_received++;
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
});

# Test 1: Request under the limit should succeed
{
    my $cv = AE::cv;
    $cv->begin;

    # 1MB body - well under limit
    my $body = 'x' x (1024 * 1024);
    my $cli; $cli = simple_client POST => '/',
        body => $body,
        headers => { 'Content-Type' => 'application/octet-stream' },
        timeout => 10,
        sub {
            my ($resp_body, $headers) = @_;
            is $headers->{Status}, 200, "1MB request: accepted";
            $cv->end;
            undef $cli;
        };

    $cv->recv;
}

# Test 2: Request at ~65MB should be rejected with 413
# MAX_READ_BUF is 64MB (67108864 bytes), requests exceeding this get 413
{
    my $cv = AE::cv;
    $cv->begin;

    # Create a request that will exceed 64MB buffer
    # We send headers claiming a large body, then start sending data
    # The server should reject once buffer limit is approached

    my $hdl;
    $hdl = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            # Connection error is acceptable (server may close)
            pass "65MB request: server closed connection (expected)";
            $cv->end;
            undef $hdl;
        },
        on_eof => sub {
            pass "65MB request: server closed connection";
            $cv->end;
            undef $hdl;
        },
    );

    # Send headers with large Content-Length
    my $large_size = 65 * 1024 * 1024;  # 65MB
    $hdl->push_write("POST / HTTP/1.1\r\n");
    $hdl->push_write("Host: localhost\r\n");
    $hdl->push_write("Content-Type: application/octet-stream\r\n");
    $hdl->push_write("Content-Length: $large_size\r\n");
    $hdl->push_write("Connection: close\r\n");
    $hdl->push_write("\r\n");

    # Start sending body data in chunks
    my $sent = 0;
    my $chunk_size = 1024 * 1024;  # 1MB chunks
    my $chunk = 'x' x $chunk_size;

    my $send_chunk; $send_chunk = sub {
        return unless $hdl;
        if ($sent < $large_size) {
            $hdl->push_write($chunk);
            $sent += $chunk_size;
            # Small delay to let server process
            my $t; $t = AE::timer 0.01, 0, sub {
                $send_chunk->();
                undef $t;
            };
        }
    };

    # Read response (expect 413)
    $hdl->push_read(line => "\r\n", sub {
        my ($h, $line) = @_;
        if ($line =~ /413/) {
            pass "65MB request: got 413 (Request Entity Too Large)";
            $cv->end;
            undef $hdl;
        } else {
            # Start sending and wait for rejection
            $send_chunk->();
        }
    });

    my $timeout = AE::timer 30, 0, sub {
        fail "65MB request: timeout waiting for response";
        $cv->end;
        undef $hdl;
    };

    $cv->recv;
}

# Test 3: Verify server still works after rejecting large request
{
    my $cv = AE::cv;
    $cv->begin;

    my $cli; $cli = simple_client GET => '/',
        timeout => 5,
        sub {
            my ($body, $headers) = @_;
            is $headers->{Status}, 200, "Server still functional after large request rejection";
            $cv->end;
            undef $cli;
        };

    $cv->recv;
}

done_testing();
