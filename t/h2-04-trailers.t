#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use H2Utils;
use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

plan skip_all => "Feersum not compiled with H2 support"
    unless $evh->has_h2();

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available" if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

plan tests => 9;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
$evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

$evh->psgi_request_handler(sub {
    my $env = shift;
    my $trailers = $env->{'psgix.h2.trailers'};
    my $res = "no trailers";
    if ($trailers) {
        $res = "trailers: " . join(',', @$trailers);
    }
    return [200, ['Content-Type' => 'text/plain'], [$res]];
});

h2_fork_test("H2 trailers", $port, sub {
    my $p = shift;
    my $sock = h2_connect($p);
    die "failed to connect" unless $sock;

    # Stream 1: GET with trailers
    # H2Utils::hpack_encode_headers uses [name, value] pairs
    my $headers = hpack_encode_headers(
        [':method', 'POST'],
        [':path', '/trailer'],
        [':scheme', 'https'],
        [':authority', "localhost:$p"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers));
    
    # DATA frame (no END_STREAM)
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "some data"));
    
    # Trailer HEADERS (with END_STREAM)
    my $trailers = hpack_encode_headers(
        ['x-final', 'success'],
        ['foo', 'bar'],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $trailers));

    # Read response
    my $f = h2_read_until($sock, H2_HEADERS, 1);
    die "no headers" unless $f;
    
    $f = h2_read_until($sock, H2_DATA, 1);
    die "no data" unless $f;
    
    if ($f->{payload} =~ /trailers: x-final,success,foo,bar/) {
        exit(0);
    } else {
        warn "unexpected response: $f->{payload}\n";
        exit(1);
    }
}, timeout_mult => TIMEOUT_MULT);

# Test: a request with a body but NO trailers.  The handler's "no trailers"
# branch existed but nothing ever reached it, so a bug that fabricated an empty
# trailer list - making psgix.h2.trailers defined-but-empty - was invisible.
h2_fork_test("H2 body without trailers", $port, sub {
    my $p = shift;
    my $sock = h2_connect($p);
    die "failed to connect" unless $sock;

    my $headers = hpack_encode_headers(
        [':method', 'POST'],
        [':path', '/no-trailer'],
        [':scheme', 'https'],
        [':authority', "localhost:$p"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers));
    # DATA carrying END_STREAM: body ends here, no trailer HEADERS follows.
    $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, "some data"));

    my $f = h2_read_until($sock, H2_HEADERS, 1);
    die "no headers" unless $f;
    $f = h2_read_until($sock, H2_DATA, 1);
    die "no data" unless $f;

    exit(0) if $f->{payload} =~ /^no trailers$/;
    warn "unexpected response: $f->{payload}\n";
    exit(1);
}, timeout_mult => TIMEOUT_MULT);

# Test: Multi-frame body before trailers
h2_fork_test("H2 multi-frame body + trailers", $port, sub {
    my $p = shift;
    my $sock = h2_connect($p);
    die "failed to connect" unless $sock;

    my $headers = hpack_encode_headers(
        [':method', 'POST'],
        [':path', '/multi-frame-trailer'],
        [':scheme', 'https'],
        [':authority', "localhost:$p"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers));

    # Send multiple DATA frames (no END_STREAM)
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "chunk1"));
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "chunk2"));
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "chunk3"));

    # Trailer HEADERS (with END_STREAM)
    my $trailers = hpack_encode_headers(
        ['x-checksum', 'abc123'],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $trailers));

    # Read response
    my $f = h2_read_until($sock, H2_HEADERS, 1);
    die "no headers" unless $f;

    $f = h2_read_until($sock, H2_DATA, 1);
    die "no data" unless $f;

    if ($f->{payload} =~ /trailers: x-checksum,abc123/) {
        exit(0);
    } else {
        warn "unexpected response: $f->{payload}\n";
        exit(1);
    }
}, timeout_mult => TIMEOUT_MULT);

# Test: native interface $req->trailers() (same field, method access)
$evh->request_handler(sub {
    my $r = shift;
    my $t = $r->trailers;
    my $res = $t ? "trailers: " . join(',', @$t) : "no trailers";
    $r->send_response(200, ['Content-Type' => 'text/plain'], [$res]);
});

h2_fork_test("H2 native trailers method", $port, sub {
    my $p = shift;
    my $sock = h2_connect($p);
    die "failed to connect" unless $sock;

    my $headers = hpack_encode_headers(
        [':method', 'POST'],
        [':path', '/native-trailer'],
        [':scheme', 'https'],
        [':authority', "localhost:$p"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers));
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "payload"));
    my $trailers = hpack_encode_headers(
        ['x-native', 'yes'],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $trailers));

    my $f = h2_read_until($sock, H2_HEADERS, 1);
    die "no headers" unless $f;
    $f = h2_read_until($sock, H2_DATA, 1);
    die "no data" unless $f;

    if ($f->{payload} =~ /trailers: x-native,yes/) {
        exit(0);
    } else {
        warn "unexpected response: $f->{payload}\n";
        exit(1);
    }
}, timeout_mult => TIMEOUT_MULT);

# plan is declared above; no done_testing (having both is a footgun)
