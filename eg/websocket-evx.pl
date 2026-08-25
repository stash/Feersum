#!/usr/bin/env perl
# WebSocket example using Net::WebSocket::EVx (pure-Perl WS frames + EV I/O).
#
# Net::WebSocket::EVx handles the WS handshake and frame parsing, while
# Feersum's io() provides the socket (transparent for plain/TLS/H2).
#
# Usage:
#   perl eg/websocket-evx.pl [--port 5001] [--tls]
#
# Test:
#   wscat -c ws://localhost:5001/ws
#   wscat -c wss://localhost:5001/ws  (with --tls)
#
# Requires: Net::WebSocket::EVx, Digest::SHA1
use strict;
use warnings;
use EV;
use Feersum;
use IO::Socket::INET;
use Socket qw(SOMAXCONN);
use Getopt::Long;

eval { require Net::WebSocket::EVx; 1 }
    or die "Net::WebSocket::EVx required: cpanm Net::WebSocket::EVx\n";
eval { require Digest::SHA1; Digest::SHA1->import('sha1_base64'); 1 }
    or die "Digest::SHA1 required: cpanm Digest::SHA1\n";

use constant WS_GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

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
    $feer->set_tls(cert_file => $cert, key_file => $key);
}

my $scheme = $use_tls ? 'wss' : 'ws';
print "WebSocket (Net::WebSocket::EVx) on $scheme://localhost:$port/ws\n";

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

    # WS handshake: compute Sec-WebSocket-Accept
    my $ws_key = $r->header('sec-websocket-key') || '';
    my $accept = sha1_base64($ws_key . WS_GUID) . '=';

    # Get tunnel socket (works for plain, TLS, H2)
    my $io = $r->io();
    return unless $io;

    # Send 101 Switching Protocols
    syswrite($io, "HTTP/1.1 101 Switching Protocols\015\012" .
                   "Upgrade: websocket\015\012" .
                   "Connection: Upgrade\015\012" .
                   "Sec-WebSocket-Accept: $accept\015\012\015\012");

    my $id = ++$next_id;

    # Net::WebSocket::EVx wraps the socket with EV watchers for automatic
    # frame parsing and async send.  new() takes ONE hashref, and the
    # callbacks are wired in the constructor rather than registered after it.
    my $ws;
    $ws = Net::WebSocket::EVx->new({
        fh => $io,
        on_msg_recv => sub {
            my (undef, undef, $msg, undef) = @_;   # rsv, opcode, payload, status
            print "[$id] $msg\n";
            if ($msg eq '/users') {
                $ws->queue_msg("Online: " . join(', ', sort keys %clients));
            } elsif ($msg =~ m{^/broadcast (.+)}) {
                $_->queue_msg("#$id: $1") for values %clients;
            } else {
                $ws->queue_msg("echo: $msg");
            }
        },
        on_close => sub {
            print "[$id] disconnected\n";
            delete $clients{$id};
            undef $ws;
        },
    });

    $clients{$id} = $ws;
    # queue_msg only queues; the watchers have to be running to move it.
    $ws->start;
    $ws->queue_msg("Welcome #$id! Commands: /users, /broadcast <msg>");
    print "[$id] connected\n";
});

EV::run;
