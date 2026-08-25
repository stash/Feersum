#!/usr/bin/env perl
# Test pipeline depth limit (MAX_PIPELINE_DEPTH = 15)
# Verifies the server handles deep pipelines without stack overflow
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

my $request_count = 0;
$feer->request_handler(sub {
    my $r = shift;
    $request_count++;
    $r->send_response(200, ['Content-Type' => 'text/plain'], ["req$request_count"]);
});

#######################################################################
# Test: Send 20 pipelined requests (exceeds MAX_PIPELINE_DEPTH of 15)
# The server should defer processing to event loop, not crash or stack overflow
#######################################################################
{
    my $num_requests = 20;  # More than MAX_PIPELINE_DEPTH (15)
    my $cv = AE::cv;

    my $buffer = '';
    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            fail "client error: $msg";
            $cv->send;
        },
        on_eof => sub {
            # Count responses
            my @responses = $buffer =~ /HTTP\/1\.1 200 OK/g;
            is scalar(@responses), $num_requests, "got all $num_requests responses";

            # Verify all response bodies are present
            my @bodies = $buffer =~ /req(\d+)/g;
            is scalar(@bodies), $num_requests, "got all $num_requests response bodies";

            # Verify responses are in order
            my $in_order = 1;
            for my $i (1 .. $num_requests) {
                unless ($bodies[$i-1] == $i) {
                    $in_order = 0;
                    last;
                }
            }
            ok $in_order, "responses are in correct order";

            $h->destroy;
            $cv->send;
        },
        on_read => sub {
            $buffer .= $_[0]->rbuf;
            $_[0]->rbuf = '';
        }
    );

    # Build pipelined requests - all but last use keepalive
    my $requests = '';
    for my $i (1 .. $num_requests - 1) {
        $requests .= "GET /req$i HTTP/1.1\r\nHost: localhost\r\n\r\n";
    }
    # Last request with Connection: close
    $requests .= "GET /req$num_requests HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    $h->push_write($requests);
    $cv->recv;

    is $request_count, $num_requests, "handler called $num_requests times";
}

#######################################################################
# Test: Even deeper pipeline (30 requests)
#######################################################################
{
    $request_count = 0;
    my $num_requests = 30;
    my $cv = AE::cv;

    my $buffer = '';
    my $h; $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            fail "client error on deep pipeline: $msg";
            $cv->send;
        },
        on_eof => sub {
            my @responses = $buffer =~ /HTTP\/1\.1 200 OK/g;
            is scalar(@responses), $num_requests, "deep pipeline: got all $num_requests responses";
            $h->destroy;
            $cv->send;
        },
        on_read => sub {
            $buffer .= $_[0]->rbuf;
            $_[0]->rbuf = '';
        }
    );

    my $requests = '';
    for my $i (1 .. $num_requests - 1) {
        $requests .= "GET /deep$i HTTP/1.1\r\nHost: localhost\r\n\r\n";
    }
    $requests .= "GET /deep$num_requests HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    $h->push_write($requests);
    $cv->recv;

    is $request_count, $num_requests, "deep pipeline: handler called $num_requests times";
}

done_testing;
