#!/usr/bin/env perl
# Feersum backend on Unix socket with WebSocket and SSE
# Supports PROXY Protocol v1/v2 for L4 TLS termination
#
# Usage: perl eg/ssl-proxy/backend.pl
#
# With PROXY Protocol, the frontend (stunnel, haproxy, nginx) sends:
#   - Real client IP address -> $env->{REMOTE_ADDR}
#   - Destination port        -> used for scheme inference
#   - SSL/TLS status (PROXY v2 PP2_TYPE_SSL only) -> psgi.url_scheme "https"
#
use strict;
use warnings;
use AnyEvent;
use Plack::Handler::Feersum;
use Protocol::WebSocket::Handshake::Server;
use Protocol::WebSocket::Frame;

my $SOCKET_PATH = $ENV{SOCKET_PATH} || '/tmp/feersum.sock';
unlink $SOCKET_PATH if -e $SOCKET_PATH;
print "Backend starting on $SOCKET_PATH (PROXY protocol enabled)\n";

my $app = sub {
    my $env = shift;
    my $path = $env->{PATH_INFO} || '/';

    # Home page with demos
    if ($path eq '/') {
        my $remote_addr = $env->{REMOTE_ADDR} || 'unknown';
        my $scheme = $env->{'psgi.url_scheme'} || 'http';
        return [200, ['Content-Type' => 'text/html'], [<<"HTML"]];
<!DOCTYPE html>
<html>
<head><title>Feersum SSL Proxy Demo</title>
<style>
body{font-family:monospace;background:#1a1a2e;color:#eee;padding:20px}
h1{color:#0f0} h2{color:#0aa} h3{color:#aa0}
pre{background:#000;padding:10px;max-height:200px;overflow:auto}
button{background:#0a0;color:#fff;border:none;padding:8px 16px;margin:4px;cursor:pointer}
.info{background:#003;padding:10px;margin-bottom:20px}
</style></head>
<body>
<h1>Feersum SSL Proxy Demo</h1>

<div class="info">
<h3>Connection Info (from PROXY Protocol)</h3>
<pre>REMOTE_ADDR: $remote_addr
psgi.url_scheme: $scheme</pre>
<a href="/info" style="color:#0f0">View full connection details</a>
</div>

<h2>Server-Sent Events</h2>
<button onclick="startSSE()">Start SSE</button>
<button onclick="stopSSE()">Stop</button>
<pre id="sse"></pre>

<h2>WebSocket</h2>
<button onclick="startWS()">Connect</button>
<button onclick="sendWS()">Send Ping</button>
<button onclick="stopWS()">Close</button>
<pre id="ws"></pre>

<script>
let sse, ws;
function log(id, msg) { document.getElementById(id).textContent += msg + '\\n'; }

function startSSE() {
  sse = new EventSource('/sse');
  sse.onmessage = e => log('sse', 'data: ' + e.data);
  sse.onerror = () => log('sse', 'SSE error/closed');
}
function stopSSE() { sse && sse.close(); }

function startWS() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(proto + '//' + location.host + '/ws');
  ws.onopen = () => log('ws', 'Connected');
  ws.onmessage = e => log('ws', 'Received: ' + e.data);
  ws.onclose = () => log('ws', 'Closed');
}
function sendWS() { ws && ws.send('ping ' + Date.now()); }
function stopWS() { ws && ws.close(); }
</script>
</body>
</html>
HTML
    }

    # Server-Sent Events
    elsif ($path eq '/sse') {
        return sub {
            my $respond = shift;
            my $w = $respond->([200, [
                'Content-Type' => 'text/event-stream',
                'Cache-Control' => 'no-cache',
            ]]);
            my $count = 0;
            my $t; $t = AE::timer 0, 1, sub {
                eval { $w->write("data: tick " . ++$count . " @ " . localtime() . "\n\n") };
                if ($@ || $count >= 30) { undef $t; eval { $w->close } }
            };
        };
    }

    # WebSocket
    elsif ($path eq '/ws') {
        my $io = $env->{'psgix.io'} or return [500, [], ['No psgix.io']];
        my $hs = Protocol::WebSocket::Handshake::Server->new_from_psgi($env);
        $hs->parse('');
        unless ($hs->is_done) {
            return [400, [], ['Bad handshake']];
        }
        syswrite $io, $hs->to_string;

        my $frame = Protocol::WebSocket::Frame->new;
        my $w; $w = AE::io $io, 0, sub {
            my $buf;
            my $n = sysread $io, $buf, 8192;
            unless ($n) { undef $w; close $io; return }
            $frame->append($buf);
            while (defined(my $msg = $frame->next)) {
                my $reply = Protocol::WebSocket::Frame->new(buffer => "echo: $msg")->to_bytes;
                syswrite $io, $reply;
            }
        };
        return;
    }

    # Info endpoint - shows connection info including PROXY protocol data
    elsif ($path eq '/info') {
        my @lines = (
            "=== Connection Info (from PROXY Protocol) ===",
            "REMOTE_ADDR: $env->{REMOTE_ADDR}",
            "REMOTE_PORT: $env->{REMOTE_PORT}",
            "psgi.url_scheme: $env->{'psgi.url_scheme'}",
            "",
            "=== Request Headers ===",
        );
        push @lines, map { "$_: $env->{$_}" } sort grep /^(REQUEST_|PATH_|SERVER_|HTTP_)/, keys %$env;
        return [200, ['Content-Type' => 'text/plain'], [join("\n", @lines) . "\n"]];
    }

    else { return [404, ['Content-Type' => 'text/plain'], ["Not Found\n"]] }
};

# Enable PROXY protocol for L4 TLS termination
# This allows the frontend to send real client IP and SSL status
Plack::Handler::Feersum->new(
    listen => [$SOCKET_PATH],
    quiet  => 1,
    proxy_protocol => 1,  # Enable PROXY protocol v1/v2
)->run($app);
END { unlink $SOCKET_PATH if -e $SOCKET_PATH }
