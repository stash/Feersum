#!/usr/bin/env perl
# HTTP/2 over TLS.  ALPN picks h2 when the client offers it and falls back to
# HTTP/1.1 when it does not, on the same listener - there is no separate port
# and no h2c (cleartext HTTP/2), which browsers do not speak anyway.
#
#   perl eg/h2-server.pl
#   curl -k --http2 https://localhost:5001/          # h2
#   curl -k --http1.1 https://localhost:5001/        # same socket, HTTP/1.1
#   nghttp -nv https://localhost:5001/ https://localhost:5001/slow   # multiplexed
use strict;
use warnings;
use EV;
use Feersum;
use IO::Socket::INET;

my $CERT = 'eg/ssl-proxy/server.crt';
my $KEY  = 'eg/ssl-proxy/server.key';
die "run from the distribution root: $CERT not found\n" unless -f $CERT;

my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:5001',
    Proto     => 'tcp',
    Listen    => 1024,
    ReuseAddr => 1,
) or die "listen: $!";

my $feersum = Feersum->endjinn;
$feersum->use_socket($socket);
# h2 => 1 adds "h2" to the ALPN list; without it the same listener serves
# HTTP/1.1 over TLS only.
$feersum->set_tls(cert_file => $CERT, key_file => $KEY, h2 => 1);
$feersum->set_keepalive(1);

$feersum->psgi_request_handler(sub {
    my $env = shift;

    # A slow response, so several concurrent streams visibly interleave
    # rather than queueing behind one another as they would on HTTP/1.1.
    if (($env->{PATH_INFO} // '') eq '/slow') {
        return sub {
            my $respond = shift;
            my $w = $respond->([200, ['Content-Type' => 'text/plain']]);
            my $n = 0;
            my $t; $t = EV::timer 0, 0.25, sub {
                $w->write("chunk " . ++$n . "\n");
                if ($n >= 4) { $w->close; undef $t }
            };
        };
    }

    my $proto = $env->{SERVER_PROTOCOL};          # HTTP/2 or HTTP/1.1
    return [200, [q{Content-Type} => q{text/plain}],
            ["served over $proto\n",
             $proto eq q{HTTP/2} ? "ALPN negotiated h2\n"
                                 : "ALPN fell back to HTTP/1.1\n",
             "scheme: $env->{q{psgi.url_scheme}}\n"]];
});

warn "listening on https://localhost:5001/ (h2 + http/1.1 via ALPN)\n";
EV::run;
