#!perl
# Test wbuf_low_water works under TLS - poll_cb fires mid-encryption-loop
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available"
    if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 6;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file) };
is $@, '', "TLS configured";

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

$evh->wbuf_low_water(8192);

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

run_client "TLS low-water streaming", sub {
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port,
        SSL_verify_mode => 0,
    ) or do { warn "TLS connect failed: $!\n"; return 1 };

    $cl->print("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");

    my $body = '';
    while (my $n = $cl->sysread(my $buf, 65536)) {
        $body .= $buf;
    }
    $cl->close;

    # Strip HTTP headers
    $body =~ s/\A.*?\r\n\r\n//s;
    my $expected = $chunk_size * $max_chunks;
    if (length($body) != $expected) {
        warn "expected $expected bytes, got " . length($body) . "\n";
        return 1;
    }
    return 0;
};

cmp_ok $cb_count, '>=', 1, "poll_cb fired at least once ($cb_count times)";

$evh->wbuf_low_water(0);
pass "done";
