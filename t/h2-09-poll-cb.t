#!perl
# Test H2 streaming with poll_cb - verifies poll_cb fires for H2 pseudo-conns
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
plan skip_all => "no test certificates"
    unless -f $cert_file && -f $key_file;

my $nghttp_bin = `which nghttp 2>/dev/null`;
chomp $nghttp_bin;
plan skip_all => "nghttp not found in PATH"
    unless $nghttp_bin && -x $nghttp_bin;

plan tests => 9;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "TLS+H2 configured";

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

# ===========================================================================
# Part 1: H2 streaming with poll_cb
# ===========================================================================

my $cb_count = 0;
my $max_chunks = 5;
my $chunk_size = 4096;

$evh->request_handler(sub {
    my $r = shift;
    my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
    $w->write("A" x $chunk_size);
    my $chunks = 1;
    $w->poll_cb(sub {
        $cb_count++;
        $chunks++;
        if ($chunks <= $max_chunks) {
            $w->write("B" x $chunk_size);
        }
        if ($chunks >= $max_chunks) {
            $w->poll_cb(undef);
            $w->close();
        }
    });
});

# Fork nghttp client
my $expected_len = $chunk_size * $max_chunks;
run_client "H2 poll_cb streaming", sub {
    my $output = `$nghttp_bin --no-verify https://127.0.0.1:$port/test 2>/dev/null`;
    my $rc = $? >> 8;
    if ($rc != 0) {
        warn "nghttp exited $rc\n";
        return 1;
    }
    my $got_len = length($output);
    if ($got_len != $expected_len) {
        warn "expected $expected_len bytes, got $got_len\n";
        return 1;
    }
    return 0;
};

cmp_ok $cb_count, '>=', 1, "poll_cb fired at least once ($cb_count times)";

# ===========================================================================
# Part 2: H2 streaming with poll_cb and wbuf_low_water
# ===========================================================================

$cb_count = 0;
$evh->wbuf_low_water(8192);

$evh->request_handler(sub {
    my $r = shift;
    my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
    $w->write("C" x $chunk_size);
    my $chunks = 1;
    $w->poll_cb(sub {
        $cb_count++;
        $chunks++;
        if ($chunks <= $max_chunks) {
            $w->write("D" x $chunk_size);
        }
        if ($chunks >= $max_chunks) {
            $w->poll_cb(undef);
            $w->close();
        }
    });
});

run_client "H2 poll_cb + low water", sub {
    my $output = `$nghttp_bin --no-verify https://127.0.0.1:$port/test2 2>/dev/null`;
    my $rc = $? >> 8;
    if ($rc != 0) {
        warn "nghttp exited $rc\n";
        return 1;
    }
    my $got_len = length($output);
    if ($got_len != $expected_len) {
        warn "expected $expected_len bytes, got $got_len\n";
        return 1;
    }
    return 0;
};

cmp_ok $cb_count, '>=', 1, "poll_cb fired with low_water ($cb_count times)";

$evh->wbuf_low_water(0);  # reset
pass "done";
