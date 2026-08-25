#!/usr/bin/env perl
# Test malicious/buggy clients sending wrong body lengths.
# Covers: CL too large (body short), CL too small (body overflow),
# chunk size mismatch, and interaction with keepalive/pipelining.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

plan tests => 20;

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
$feer->read_timeout(2 * TMULT);

my @requests;
$feer->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    my $cl = $env->{CONTENT_LENGTH} || 0;
    if ($cl > 0) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    push @requests, { path => $env->{PATH_INFO}, body => $body, cl => $cl };
    $r->send_response(200, ['Content-Type' => 'text/plain',
                            'Content-Length' => length("OK")], \"OK");
});

sub raw_request {
    my ($request, $timeout) = @_;
    # Must exceed the server read_timeout (2*TMULT) by a wide margin: on a loaded
    # box a scheduling gap can span the server deadline, and a wait only just
    # above it lets this timer fire before the io watcher reads the 408.
    $timeout ||= 10 * TMULT;
    my $cv = AE::cv;
    my $response = '';
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send },
        on_eof   => sub { $cv->send },
    );
    $h->push_write($request);
    $h->on_read(sub { $response .= $h->rbuf; $h->rbuf = '' });
    my $t = AE::timer($timeout, 0, sub { $cv->send });
    $cv->recv;
    return $response;
}

###########################################################################
# Test 1: CL too large - client sends fewer bytes than declared
#         Server should wait for body (read_timeout will kill it)
###########################################################################
{
    @requests = ();
    # CL says 100 but we only send 5 bytes then close
    my $response = raw_request(
        "POST /cl-too-large HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 100\r\n" .
        "Connection: close\r\n\r\n" .
        "hello"
    );
    # Server waits for remaining 95 bytes, times out or gets EOF
    # Either way, the handler should NOT be called (body incomplete)
    is scalar(@requests), 0, 'CL too large: handler not called (body incomplete)';
    like $response, qr{^HTTP/1\.[01] 408\b},
        'CL too large: client is told the request timed out';
}

###########################################################################
# Test 2: CL too small - client sends more bytes than declared
#         Extra bytes should NOT leak into handler's body
###########################################################################
{
    @requests = ();
    my $response = raw_request(
        "POST /cl-too-small HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 3\r\n" .
        "Connection: close\r\n\r\n" .
        "helloworld_extra_garbage"
    );
    like $response, qr/HTTP\/1\.1 200/, 'CL too small: got 200 response';
    is scalar(@requests), 1, 'CL too small: handler called once';
    is $requests[0]{body}, 'hel', 'CL too small: body limited to CL bytes';
}

###########################################################################
# Test 3: CL too small + pipelined GET - extra bytes must not be
#         parsed as HTTP (the body drain should handle this)
###########################################################################
{
    @requests = ();
    # CL says 5 but we send 10 bytes of body, then pipeline a GET
    my $response = raw_request(
        "POST /overflow HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 5\r\n" .
        "\r\n" .
        "helloEXTRA" .  # 10 bytes but CL=5, so "EXTRA" is overflow
        "GET /after HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n\r\n"
    );
    # POST body should be "hello" (5 bytes per CL).
    # "EXTRA" is past CL - treated as pipelined data (not valid HTTP).
    # The key test: does the POST handler get exactly 5 bytes?
    ok scalar(@requests) >= 1, 'CL overflow + pipeline: at least POST served';
    is $requests[0]{body}, 'hello', 'CL overflow: POST body is exactly CL bytes';
}

###########################################################################
# Test 4: CL=0 with body bytes - body should be ignored
###########################################################################
{
    @requests = ();
    my $response = raw_request(
        "POST /cl-zero HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 0\r\n" .
        "Connection: close\r\n\r\n" .
        "surprise_body"
    );
    like $response, qr/200/, 'CL=0 with body: got response';
    is scalar(@requests), 1, 'CL=0: handler called';
    is $requests[0]{body}, '', 'CL=0: body is empty (extra data ignored)';
}

###########################################################################
# Test 5: Huge CL - server should not allocate huge buffer before data
###########################################################################
{
    @requests = ();
    my $response = raw_request(
        "POST /huge-cl HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 999999999\r\n" .
        "Connection: close\r\n\r\n" .
        "tiny"
    );
    # Should timeout waiting for body or reject (413/408)
    is scalar(@requests), 0, 'Huge CL: handler not called';
    # 999999999 exceeds MAX_BODY_LEN (64 MiB), so it is rejected on the
    # declared length alone - no buffer is ever allocated for it.
    like $response, qr{^HTTP/1\.[01] 413\b},
        'Huge CL: rejected as too large rather than buffered';
}

###########################################################################
# Test 6: Chunk declares 100 bytes but only sends 5
###########################################################################
{
    @requests = ();
    my $response = raw_request(
        "POST /chunk-short HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Transfer-Encoding: chunked\r\n" .
        "Connection: close\r\n\r\n" .
        "64\r\nhello"  # 0x64 = 100, but only 5 bytes follow
    );
    # Server waits for remaining 95 bytes, times out
    is scalar(@requests), 0, 'Chunk too short: handler not called';
    like $response, qr{^HTTP/1\.[01] 408\b},
        'Chunk too short: client is told the request timed out';
}

###########################################################################
# Test 7: Keepalive after POST with body read works
###########################################################################
{
    @requests = ();
    my $response = raw_request(
        "POST /ka1 HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Content-Length: 5\r\n" .
        "\r\n" .
        "hello" .
        "GET /ka2 HTTP/1.1\r\n" .
        "Host: localhost\r\n" .
        "Connection: close\r\n\r\n"
    );
    my @resps = ($response =~ /HTTP\/1\.1 200/g);
    is scalar(@resps), 2, 'Keepalive POST+GET: both served';
    is $requests[0]{body}, 'hello', 'Keepalive: POST body correct';
    is $requests[1]{path}, '/ka2', 'Keepalive: GET path correct';
}

###########################################################################
# Test 8: Keepalive after POST with body NOT read - body drained
###########################################################################
{
    # Use a separate server instance with a handler that skips body
    my ($s2, $p2) = get_listen_socket();
    my $feer2 = Feersum->new_instance();
    $feer2->use_socket($s2);
    $feer2->set_keepalive(1);
    my @reqs2;
    $feer2->request_handler(sub {
        my $r = shift;
        push @reqs2, $r->env->{PATH_INFO};
        # Do NOT read body
        $r->send_response(200, ['Content-Type' => 'text/plain'], \"OK");
    });

    my $cv = AE::cv;
    my $response = '';
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $p2],
        on_error => sub { $cv->send },
        on_eof   => sub { $cv->send },
    );
    $h->push_write(
        "POST /skip HTTP/1.1\r\nHost: l\r\nContent-Length: 5\r\n\r\nhello" .
        "GET /after HTTP/1.1\r\nHost: l\r\nConnection: close\r\n\r\n"
    );
    $h->on_read(sub { $response .= $h->rbuf; $h->rbuf = '' });
    my $t = AE::timer(3 * TMULT, 0, sub { $cv->send });
    $cv->recv;

    my @resps = ($response =~ /HTTP\/1\.1 200/g);
    is scalar(@resps), 2, 'Unread body + pipeline: both requests served';
    is scalar(@reqs2), 2, 'Unread body: handler called twice (body drained)';
}
