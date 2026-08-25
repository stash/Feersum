#!/usr/bin/env perl
# PROXY protocol: the load balancer prepends one header carrying the original
# client address, so the app sees the real peer instead of the balancer.
# Pair this with eg/haproxy.cfg (send-proxy-v2) or eg/nginx-stream.conf.
#
# Unlike X-Forwarded-For this is not a request header - it arrives before the
# request and cannot be forged by an HTTP client.  Which is also why the
# listener must ONLY be reachable from the balancer: with proxy_protocol on,
# anything that connects gets to state its own address.
#
#   perl eg/proxy-protocol.pl
#   printf 'PROXY TCP4 203.0.113.7 10.0.0.1 4321 5004\r\nGET / HTTP/1.0\r\n\r\n' \
#     | nc localhost 5004
use strict;
use warnings;
use EV;
use Feersum;
use IO::Socket::INET;

my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:5004',
    Proto     => 'tcp',
    Listen    => 1024,
    ReuseAddr => 1,
) or die "listen: $!";

my $feersum = Feersum->endjinn;
$feersum->use_socket($socket);
# Required, not sniffed: a connection without the header is refused with 400.
$feersum->set_proxy_protocol(1);

$feersum->request_handler(sub {
    my $req = shift;

    # Both addresses are the original client from the PROXY header, not the
    # balancer; client_address differs only if set_reverse_proxy is also on.
    my $body = sprintf "client:  %s:%s\nremote:  %s\nscheme:  %s\n",
        $req->client_address // '?', $req->remote_port // '?',
        $req->remote_address // '?', $req->url_scheme;

    # v2 can also carry TLVs - the ALPN and TLS details of the front
    # connection, when the balancer terminated TLS itself.
    if (my $tlvs = $req->proxy_tlvs) {
        $body .= sprintf "tlv %s: %s\n", $_, $tlvs->{$_} for sort keys %$tlvs;
    }

    $req->send_response(200, ['Content-Type' => 'text/plain'], [$body]);
});

warn "listening on localhost:5004 - PROXY header required on every connection\n";
EV::run;
