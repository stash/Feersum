#!perl
# Test H2-specific response code paths:
#   1. Handler die -> feersum_h2_respond_error -> 500 HEADERS
#   2. write_array on H2 streaming response
#   3. IO::Handle body on H2 via pump_h2_io_handle
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use File::Temp qw(tempfile);
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

plan tests => 12;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

use H2Utils;

# Silence Feersum::DIED for the intentional-die tests (1 and 4).
{ no warnings 'redefine'; *Feersum::DIED = sub { }; }

# ========================================================================
# Test 1: Handler die -> 500 HEADERS via feersum_h2_respond_error
# ========================================================================
$evh->request_handler(sub {
    die "intentional test error\n";
});

h2_fork_test("handler die -> 500", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/die-test'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    # Expect a HEADERS frame with :status 500, or RST_STREAM
    my $got_500 = 0;
    my $got_rst = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            my $status = hpack_decode_status($f->{payload});
            $got_500 = 1 if defined $status && $status eq '500';
            last;
        }
        if ($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) {
            $got_rst = 1;
            last;
        }
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    exit(0) if $got_500 || $got_rst;
    exit(2);
});

# ========================================================================
# Test 2: write_array on H2 streaming response
# ========================================================================
$evh->request_handler(sub {
    my $r = shift;
    my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain']);
    $w->write_array([
        "chunk-one\n",
        "chunk-two\n",
        \"chunk-three\n",  # scalar ref variant
    ]);
    $w->close();
});

h2_fork_test("write_array on H2", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/write-array'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    # Read HEADERS + DATA frames
    my $got_200 = 0;
    my $body = '';
    my $got_end_stream = 0;
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
            $got_end_stream = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        last if $got_end_stream;
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();

    exit(2) unless $got_200;
    # Verify all three chunks arrived
    exit(3) unless $body =~ /chunk-one/;
    exit(4) unless $body =~ /chunk-two/;
    exit(5) unless $body =~ /chunk-three/;
    exit(0);
});

# Allow event loop to drain between tests
{ my $cv = AE::cv; my $t = AE::timer(0.5 * TIMEOUT_MULT, 0, sub { $cv->send }); $cv->recv; }

# ========================================================================
# Test 3: IO::Handle body on H2 via pump_h2_io_handle
# ========================================================================

# Create a temp file to serve as IO::Handle body
my $io_body = "line1-from-iohandle\nline2-from-iohandle\n";
my ($tmpfh, $tmpfile) = tempfile(UNLINK => 1);
print $tmpfh $io_body;
close $tmpfh;

$evh->psgi_request_handler(sub {
    my $env = shift;
    open my $fh, '<', $tmpfile or die "open $tmpfile: $!";
    return [200, ['Content-Type' => 'text/plain'], $fh];
});

h2_fork_test("IO::Handle body on H2", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/io-handle'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    my $got_200 = 0;
    my $body = '';
    my $got_end_stream = 0;
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
            $got_end_stream = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        last if $got_end_stream;
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();

    exit(2) unless $got_200;
    exit(3) unless $body =~ /line1-from-iohandle/;
    exit(4) unless $body =~ /line2-from-iohandle/;
    exit(0);
});

# ========================================================================
# Test 3b: an IO::Handle body larger than the initial flow-control window
# streams over H2 intact (per-chunk flush, then the loop-driven remainder).
# ========================================================================
my $big = join('', map { sprintf("%06d-payload-line\n", $_) } 0 .. 11999);
my ($bigfh, $bigfile) = tempfile(UNLINK => 1);
binmode $bigfh; print $bigfh $big; close $bigfh;

$evh->psgi_request_handler(sub {
    my $env = shift;
    open my $fh, '<', $bigfile or die "open $bigfile: $!";
    binmode $fh;
    return [200, ['Content-Type' => 'application/octet-stream'], $fh];
});

h2_fork_test("large IO::Handle body on H2", $port, sub {
    my ($port) = @_;
    my $sock = h2_connect($port);
    exit(1) unless $sock;
    my $hb = hpack_encode_headers(
        [':method',   'GET'], [':path', '/big'], [':scheme', 'https'],
        [':authority', "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                             1, $hb));
    my ($got_200, $body, $end) = (0, '', 0);
    my $deadline = time + 20 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            my $s = hpack_decode_status($f->{payload});
            $got_200 = 1 if defined $s && $s eq '200';
        }
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $body .= $f->{payload};
            $end = 1 if $f->{flags} & FLAG_END_STREAM;
            # keep both windows open so a >window body can fully drain
            if (my $n = length $f->{payload}) {
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $n)));
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', $n)));
            }
        }
        last if $end;
    }
    $sock->close();
    exit(2) unless $got_200;
    exit(5) unless length($body) == length($big);
    exit(6) unless $body eq $big;
    exit(0);
}, timeout => 20, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 4: Handler die during streaming -> RST_STREAM
# ========================================================================
$evh->request_handler(sub {
    my $r = shift;
    my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain']);
    $w->write("partial data\n");
    die "intentional streaming error\n";
});

h2_fork_test("handler die during streaming -> RST", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    my $headers_block = hpack_encode_headers(
        [':method',    'GET'],
        [':path',      '/die-streaming'],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              1, $headers_block));

    # Should get 200 HEADERS (from start_streaming), then RST_STREAM
    my $got_headers = 0;
    my $got_rst = 0;
    my $got_end_stream = 0;
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $got_headers = 1;
        }
        if ($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) {
            $got_rst = 1;
            last;
        }
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $got_end_stream = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        last if $got_end_stream;
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();

    # Either RST_STREAM or a clean close is acceptable
    exit(0) if $got_rst || $got_end_stream;
    exit(2);
});

