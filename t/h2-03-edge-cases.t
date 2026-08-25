#!perl
# Test H2-specific edge cases:
#   1. Non-standard method (PROPFIND) reaches handler (H2 has no method filter)
#   2. max_body_len enforcement on H2 streams
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

plan tests => 17;  # +2 h2_fork_test implicit, +2 explicit

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

use H2Utils;

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

# ========================================================================
# Test 1: Non-standard method (PROPFIND) reaches H2 handler
# (H1 would reject with 405; H2 passes through)
# ========================================================================
my $got_method = '';
$evh->request_handler(sub {
    my $r = shift;
    $got_method = $r->method();
    $r->send_response(200, ['Content-Type' => 'text/plain'], $got_method);
});

h2_fork_test("PROPFIND method via H2", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'PROPFIND'],
        [':path',      '/webdav-test'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_200 = 0;
    my $body = '';
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            my $status = hpack_decode_status($f->{payload});
            $got_200 = 1 if defined $status && $status eq '200';
        }
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $body .= $f->{payload};
            last if $f->{flags} & FLAG_END_STREAM;
        }
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit(0) if $got_200 && $body eq 'PROPFIND';
    exit(2);
}, timeout_mult => TIMEOUT_MULT);

is $got_method, 'PROPFIND', "H2 handler received PROPFIND method";

# ========================================================================
# Test 2: max_body_len enforcement on H2 stream
# ========================================================================
$evh->max_body_len(100);  # small limit for testing

my $body_received = 0;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    $body_received = $env->{CONTENT_LENGTH} || 0;
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
});

h2_fork_test("max_body_len H2 rejection", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'POST'],
        [':path',      '/body-test'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    # Send HEADERS without END_STREAM (body follows)
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS,
                              1, $headers_block));

    # Send DATA exceeding max_body_len (200 bytes > 100 limit)
    my $big_body = "X" x 200;
    $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, $big_body));

    # Expect RST_STREAM or GOAWAY (TEMPORAL_CALLBACK_FAILURE triggers reset)
    # or connection close (server may close TLS after error)
    my $got_error = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        if (!$f) {
            # Weak evidence on its own (h2_read_frame also returns undef on its
            # deadline); the parent's $body_received assertion is the real check.
            # No sysread() probe for EOF here: it steals a byte from the TLS stream.
            $got_error = 1;
            last;
        }
        if ($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) {
            $got_error = 1;
            last;
        }
        if ($f->{type} == H2_GOAWAY) {
            $got_error = 1;
            last;
        }
    }

    $sock->close();
    exit($got_error ? 0 : 2);
}, timeout_mult => TIMEOUT_MULT);

is $body_received, 0,
    'handler never received the oversized body';

# ========================================================================
# Administrative limits produce a real HTTP status on H2, as on H1, not a
# stream reset with INTERNAL_ERROR (which RFC 9113 reserves for the endpoint's
# own faults and which leaves the client with no status at all).
# ========================================================================
$evh->max_uri_len(200);

h2_fork_test("H2 over-long :path answers 414", $port, sub {
    my ($port) = @_;
    my $sock = h2_connect($port) or exit(1);

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/' . ('a' x 300)],       # > max_uri_len 200
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $status;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        exit(3) if $f->{type} == H2_RST_STREAM && $f->{stream_id} == 1;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $status = hpack_decode_status($f->{payload});
            last;
        }
    }
    $sock->close();
    exit(0) if defined $status && $status eq '414';
    exit(4);
}, timeout_mult => TIMEOUT_MULT);

h2_fork_test("H2 declared over-limit content-length answers 413", $port, sub {
    my ($port) = @_;
    my $sock = h2_connect($port) or exit(1);

    my $headers_block = hpack_encode_headers(
        [':method',        'POST'],
        [':path',          '/big'],
        [':scheme',        'https'],
        [':authority',      "127.0.0.1:$port"],
        ['content-length', '5000'],              # > max_body_len 100
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers_block));
    # Keep sending after the refusal: the response must survive the DATA that
    # follows it (the overflow path used to RST a stream already answered).
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, 'X' x 1000));

    my $status;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        exit(3) if $f->{type} == H2_RST_STREAM && $f->{stream_id} == 1;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $status = hpack_decode_status($f->{payload});
            last;
        }
    }
    $sock->close();
    exit(0) if defined $status && $status eq '413';
    exit(4);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 2b: max_body_len with no content-length (streaming upload).  The DATA
# callback cannot reject by return value (nghttp2 acts only on PAUSE and fatal
# codes there), so the cap must be enforced explicitly rather than truncate.
# ========================================================================
my $nocl_dispatched = 0;
my $nocl_len = -1;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    $nocl_dispatched++;
    my $body = '';
    if (my $in = $env->{'psgi.input'}) {
        $in->read($body, $env->{CONTENT_LENGTH} || 0);
    }
    $nocl_len = length $body;
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
});

h2_fork_test("max_body_len H2 (no content-length)", $port, sub {
    my ($port) = @_;
    my $sock = h2_connect($port);
    exit(1) unless $sock;
    my $headers_block = hpack_encode_headers(
        [':method',    'POST'],
        [':path',      '/nocl'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    # Deliberately NO content-length header.
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers_block));
    my $chunk = "Y" x 100;
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, $chunk)) for 1 .. 4;
    $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, $chunk));
    # Drain briefly so the server can react; the parent assertions below are
    # what actually decide the result.
    my $deadline = time + 3;
    while (time < $deadline) { last unless h2_read_frame($sock, $deadline - time) }
    $sock->close();
    exit(0);
}, timeout_mult => TIMEOUT_MULT);

is $nocl_dispatched, 0,
    'no-content-length body over max_body_len is not dispatched to the app';
isnt $nocl_len, 100,
    'app never received a silently truncated body';

$evh->max_body_len(0);  # reset to default

pass "done";
