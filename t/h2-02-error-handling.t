#!perl
# Test H2 error handling: GOAWAY on protocol errors, RST_STREAM,
# and server resilience after bad H2 frames.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

plan skip_all => "Feersum not compiled with H2 support"
    unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available"
    if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

my @received;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    push @received, $env->{PATH_INFO} || '/';
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
});

use H2Utils;

# ========================================================================
# Test 1: Send garbage after H2 preface -> expect GOAWAY
# ========================================================================
h2_fork_test("garbage after preface", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Send garbage that isn't a valid H2 frame
    $sock->syswrite("GARBAGE GARBAGE GARBAGE\x00\x00\x00");

    # Read frames until we get GOAWAY or connection closes
    my $got_goaway = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_GOAWAY) {
            $got_goaway = 1;
            last;
        }
    }
    $sock->close();
    exit($got_goaway ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 2: Invalid H2 frame on stream 0 -> expect GOAWAY
# (Send a DATA frame on stream 0, which is a protocol error per RFC 7540)
# ========================================================================
h2_fork_test("DATA on stream 0", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # DATA on stream 0 is a protocol error
    $sock->syswrite(h2_frame(H2_DATA, 0, 0, "bogus data on stream 0"));

    my $got_goaway = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_GOAWAY) {
            $got_goaway = 1;
            last;
        }
    }
    $sock->close();
    exit($got_goaway ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 3: Server survives protocol errors - new connections still work
# ========================================================================
h2_fork_test("recovery", $port, sub {
    my ($port) = @_;

    # Normal H2 request via TLS should work after all the abuse above
    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/recovery'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_response = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $got_response = 1;
            last;
        }
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_response ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT, delay => 0.5);

# @received was captured and never asserted: "a HEADERS frame arrived" is also
# true of an error response, so pin that the request reached the app.
is $received[-1], '/recovery',
    'recovery: request reached the app after the preceding abuse';

# ========================================================================
# Test 4: Plain CONNECT (no :protocol) -> 501 Not Implemented
# ========================================================================
h2_fork_test("plain CONNECT without :protocol", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Send a plain CONNECT (no :protocol, no :scheme, no :path).
    # Per RFC 9113 section 8.5, CONNECT keeps the stream open (no END_STREAM).
    my $headers_block = hpack_encode_headers(
        [':method',    'CONNECT'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS,
                              1, $headers_block));

    my $got_501 = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            my $status = hpack_decode_status($f->{payload});
            $got_501 = 1 if defined $status && $status eq '501';
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_501 ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 5: H2 PING -> PING ACK (auto-handled by nghttp2)
# ========================================================================
h2_fork_test("PING", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Send PING with 8-byte opaque data
    my $ping_data = "PingTest";
    $sock->syswrite(h2_frame(H2_PING, 0, 0, $ping_data));

    # Expect PING ACK with same data
    my $got_ack = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_PING && ($f->{flags} & FLAG_ACK) &&
            $f->{payload} eq $ping_data) {
            $got_ack = 1;
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_ack ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 6: Duplicate :method pseudo-header -> RST_STREAM
# ========================================================================
h2_fork_test("duplicate :method pseudo-header", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Send HEADERS with duplicate :method
    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':method',    'POST'],
        [':path',      '/dup-method'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_error = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        # nghttp2 may send RST_STREAM or GOAWAY for header errors
        if (($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) ||
            $f->{type} == H2_GOAWAY) {
            $got_error = 1;
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_error ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ---------------------------------------------------------------------------
# Test: Plain CONNECT (no :protocol) gets 501
# ---------------------------------------------------------------------------
h2_fork_test("plain CONNECT 501", $port, sub {
    my ($port) = @_;

    my ($sock) = h2_connect($port);
    exit(1) unless $sock;

    # Send CONNECT without :protocol (plain forward-proxy CONNECT)
    my $headers_block = hpack_encode_headers(
        [':method',    'CONNECT'],
        [':authority', '127.0.0.1:443'],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers_block));

    # Expect 501 response
    my $got_501 = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            my $status = hpack_decode_status($f->{payload});
            $got_501 = 1 if defined $status && $status eq '501';
            last;
        }
    }
    $sock->close();
    exit($got_501 ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ---------------------------------------------------------------------------
# Test: Malformed Extended CONNECT (missing :path) gets RST_STREAM
# ---------------------------------------------------------------------------
h2_fork_test("malformed Extended CONNECT RST", $port, sub {
    my ($port) = @_;

    my ($sock) = h2_connect($port);
    exit(1) unless $sock;

    # Send CONNECT with :protocol but WITHOUT :path or :scheme
    my $headers_block = hpack_encode_headers(
        [':method',    'CONNECT'],
        [':protocol',  'websocket'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers_block));

    # Expect RST_STREAM with PROTOCOL_ERROR (0x01)
    my $got_rst = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) {
            my $error_code = unpack('N', $f->{payload});
            $got_rst = 1 if $error_code == 0x01; # PROTOCOL_ERROR
            last;
        }
        # nghttp2 may also reject via GOAWAY
        if ($f->{type} == H2_GOAWAY) {
            $got_rst = 1;
            last;
        }
    }
    $sock->close();
    exit($got_rst ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test: te: gzip rejected (only te: trailers allowed in H2, RFC 9113 8.2.2)
# ========================================================================
h2_fork_test("te: gzip rejected", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/te-test'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
        ['te',         'gzip'],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_error = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if (($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) ||
            $f->{type} == H2_GOAWAY) {
            $got_error = 1;
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_error ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test: te: trailers accepted (valid per RFC 9113 8.2.2)
# ========================================================================
h2_fork_test("te: trailers accepted", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/te-trailers-ok'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
        ['te',         'trailers'],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_response = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $got_response = 1;
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_response ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

is $received[-1], '/te-trailers-ok',
    'te: trailers request reached the app';

# ========================================================================
# Test: Missing :method pseudo-header -> RST_STREAM PROTOCOL_ERROR
# ========================================================================
h2_fork_test("missing :method pseudo-header", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Send HEADERS without :method - only :path and :scheme
    my $headers_block = hpack_encode_headers(
        [':path',      '/no-method'],
        [':scheme',    'https'],
        [':authority', "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_error = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if (($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) ||
            $f->{type} == H2_GOAWAY) {
            $got_error = 1;
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_error ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test: Missing :path pseudo-header -> RST_STREAM PROTOCOL_ERROR
# ========================================================================
h2_fork_test("missing :path pseudo-header", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Send HEADERS without :path - only :method and :scheme
    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':scheme',    'https'],
        [':authority', "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_error = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if (($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) ||
            $f->{type} == H2_GOAWAY) {
            $got_error = 1;
            last;
        }
    }
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit($got_error ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test: HTTP/2 rapid reset flood (CVE-2023-44487) -> connection closed
# Open and immediately reset many streams; the server must trip its
# FEER_H2_RST_FLOOD_THRESHOLD (200 within 10s) and GOAWAY/close the conn.
# ========================================================================
h2_fork_test("rapid reset flood gets GOAWAY/close", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $hdrs = hpack_encode_headers(
        [':method', 'GET'],
        [':path', '/'],
        [':scheme', 'https'],
        [':authority', "localhost:$port"],
    );

    # 250 > threshold (200): open a stream (no END_STREAM) then RST it.
    my $sid = 1;
    for (1 .. 250) {
        $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid, $hdrs));
        $sock->syswrite(h2_frame(H2_RST_STREAM, 0, $sid, pack('N', 0x8))); # CANCEL
        $sid += 2;
    }

    # Mitigation fires as an explicit GOAWAY or a connection close.  NB
    # h2_read_frame also returns undef when its deadline expires, so "no frame"
    # must NOT count as success on its own - that made this test (the
    # CVE-2023-44487 guard) pass even with the mitigation removed.  Require
    # either a GOAWAY or a real EOF/reset on the socket.
    my $tripped = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        if ($f) {
            if ($f->{type} == H2_GOAWAY) { $tripped = 1; last }
            next;
        }
        # No frame: is the peer actually gone, or did we just time out?
        my $probe = $sock->syswrite(h2_frame(H2_PING, 0, 0, "\0" x 8));
        if (!defined $probe) { $tripped = 1; last }   # write failed: closed
        my $n = sysread($sock, my $buf, 1);
        if (defined $n && $n == 0) { $tripped = 1; last }  # clean EOF
        last;   # still connected and silent: the mitigation did not fire
    }
    $sock->close();
    exit($tripped ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

done_testing;
