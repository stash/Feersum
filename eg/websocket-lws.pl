#!/usr/bin/env perl
# WebSocket example using EV::Websockets (libwebsockets via adopt()).
#
# EV::Websockets handles the WS handshake and frame parsing natively
# via libwebsockets. Feersum parses the HTTP upgrade request, then
# hands the socket to lws via adopt(initial_data => $raw_headers).
#
# This approach gives you lws features like permessage-deflate
# compression for free.
#
# Usage:
#   perl eg/websocket-lws.pl [--port 5001] [--tls]
#
# Test:
#   wscat -c ws://localhost:5001/ws
#   wscat -c wss://localhost:5001/ws  (with --tls)
#
# Requires: EV::Websockets
use strict;
use warnings;
use EV;
use Feersum;
use EV::Websockets;
use IO::Socket::INET;
use Socket qw(SOMAXCONN);
use Getopt::Long;

my $port    = 5001;
my $use_tls = 0;
GetOptions('port=i' => \$port, 'tls!' => \$use_tls);

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';

my $sock = IO::Socket::INET->new(
    LocalAddr => "0.0.0.0:$port", ReuseAddr => 1,
    Proto => 'tcp', Listen => SOMAXCONN, Blocking => 0,
) or die "Cannot listen: $!\n";

my $feer = Feersum->endjinn;
$feer->use_socket($sock);
$feer->set_keepalive(1);

if ($use_tls) {
    die "Feersum not compiled with TLS\n" unless $feer->has_tls();
    # Create lws context BEFORE set_tls if using ssl_init => 0,
    # or AFTER set_tls with default ssl_init (recommended).
    $feer->set_tls(cert_file => $cert, key_file => $key);
}

# Create EV::Websockets context.
# ssl_init => 0 is needed if the context is created BEFORE Feersum's
# set_tls() to avoid corrupting picotls state. When created after
# set_tls() (as here), the default is fine.
my $ctx = EV::Websockets::Context->new();

my $scheme = $use_tls ? 'wss' : 'ws';
print "WebSocket (EV::Websockets/lws) on $scheme://localhost:$port/ws\n";
print "Test: wscat -c $scheme://localhost:$port/ws\n";

# Track connections for broadcast
my %clients;
my $next_id = 0;

$feer->request_handler(sub {
    my $r = shift;
    my $upgrade = $r->header('upgrade') // '';

    unless ($upgrade =~ /websocket/i) {
        $r->send_response(200, ['Content-Type' => 'text/plain'],
            \"WebSocket server. Connect with: wscat -c $scheme://localhost:$port/ws\n");
        return;
    }

    # Reconstruct raw HTTP request for lws initial_data.
    # lws needs the original HTTP upgrade request to perform
    # the WebSocket handshake (compute Sec-WebSocket-Accept, etc.)
    my $raw = $r->method() . " " . $r->uri() . " " . $r->protocol() . "\015\012";
    my $hdrs = $r->headers(0);
    while (my ($k, $v) = each %$hdrs) {
        $raw .= "$k: $v\015\012";
    }
    $raw .= "\015\012";

    # Get tunnel socket (transparent for plain/TLS/H2)
    my $io = $r->io() or return;

    my $id = ++$next_id;

    # adopt() hands the socket to libwebsockets.
    # lws reads the initial_data (the HTTP upgrade request),
    # performs the WS handshake (sends 101), and manages
    # frame parsing/serialization.
    $ctx->adopt(
        fh           => $io,
        initial_data => $raw,
        on_connect   => sub {
            my ($conn) = @_;
            $clients{$id} = $conn;
            print "[$id] connected\n";
            $conn->send("Welcome #$id! Commands: /users, /broadcast <msg>");
        },
        on_message => sub {
            my ($conn, $data) = @_;
            print "[$id] $data\n";
            if ($data eq '/users') {
                $conn->send("Online: " . join(', ', sort keys %clients));
            } elsif ($data =~ m{^/broadcast (.+)}) {
                $_->send("#$id: $1") for values %clients;
            } else {
                $conn->send("echo: $data");
            }
        },
        on_close => sub {
            print "[$id] disconnected\n";
            delete $clients{$id};
        },
        on_error => sub {
            my ($conn, $err) = @_;
            warn "[$id] error: $err\n";
            delete $clients{$id};
        },
    );
});

EV::run;
