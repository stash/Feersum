#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 8;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

#######################################################################
# Test new validations: URI length limit (414) and combined
# chunked + Expect: 100-continue
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
# Test 414 URI Too Long
#######################################################################

{
    # Create a URI that exceeds 8192 bytes
    my $long_uri = "/" . ("x" x 8200);
    my $response = raw_request(
        "GET $long_uri HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 414/, '414: URI exceeding 8192 bytes gets 414 URI Too Long');
}

{
    # A URI at exactly 8192 bytes should be OK
    my $max_uri = "/" . ("x" x 8190);  # Slightly under limit
    my $response = raw_request(
        "GET $max_uri HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );
    like($response, qr/HTTP\/1\.1 200/, 'URI at limit (8190 chars) gets 200 OK');
}

#######################################################################
# Test chunked + Expect: 100-continue combined
#######################################################################

{
    my $cv = AE::cv;
    my $got_continue = 0;
    my $full_response = '';

    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );

    # Send headers with both Transfer-Encoding: chunked and Expect: 100-continue
    $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n");

    $h->on_read(sub {
        my $data = $h->rbuf;
        $h->rbuf = '';
        $full_response .= $data;

        if (!$got_continue && $data =~ /100 Continue/) {
            $got_continue = 1;
            # Now send the chunked body
            $h->push_write("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
        }
        if ($full_response =~ /len=\d+/) {
            $cv->send;
        }
    });

    my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send; };
    $cv->recv;

    like($full_response, qr/100 Continue/i, 'Chunked+100-continue: Got 100 Continue response');
    like($full_response, qr/200 OK/, 'Chunked+100-continue: Got 200 OK final response');
    like($full_response, qr/len=11/, 'Chunked+100-continue: Body length is 11');
    like($full_response, qr/body=hello world/, 'Chunked+100-continue: Body is "hello world"');
}

pass "all validation tests completed";
