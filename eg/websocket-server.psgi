#!perl
# WebSocket PSGI example
#
# Usage:
#   plackup -s Feersum eg/websocket-server.psgi   # port 5000
#   # or
#   feersum --listen :5001 eg/websocket-server.psgi
#
# Then open http://localhost:5000/ (or :5001 for the feersum line) in
# your browser
#
# This example uses psgix.io to take over the raw socket for WebSocket.
# Requires Protocol::WebSocket module.
#
use strict;
use warnings;
use Protocol::WebSocket::Handshake::Server;
use Protocol::WebSocket::Frame;

# Track connected WebSocket clients
my %clients;
my $client_id = 0;

# HTML page with WebSocket client
my $html_page = <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <title>Feersum WebSocket Demo (PSGI)</title>
    <style>
        body { font-family: monospace; padding: 20px; background: #1a1a2e; color: #eee; }
        h1 { color: #0f0; }
        #messages { background: #16213e; padding: 15px; border-radius: 5px; max-height: 300px; overflow-y: auto; margin-bottom: 15px; }
        .msg { margin: 5px 0; padding: 5px; background: #0f3460; border-radius: 3px; }
        .msg-time { color: #e94560; }
        .msg-sent { color: #ffd700; }
        .msg-recv { color: #0f0; }
        .msg-system { color: #888; font-style: italic; }
        #status { margin: 10px 0; padding: 10px; border-radius: 5px; }
        .connected { background: #155724; }
        .disconnected { background: #721c24; }
        button, input[type="text"] { padding: 10px; border-radius: 5px; border: none; margin: 5px; }
        button { background: #e94560; color: white; cursor: pointer; }
        button:hover { background: #ff6b6b; }
        input[type="text"] { width: 300px; background: #16213e; color: #eee; }
    </style>
</head>
<body>
    <h1>Feersum WebSocket Demo (PSGI)</h1>
    <div id="status" class="disconnected">Disconnected</div>
    <button onclick="connect()">Connect</button>
    <button onclick="disconnect()">Disconnect</button>
    <h2>Messages:</h2>
    <div id="messages"></div>
    <div>
        <input type="text" id="msgInput" placeholder="Type a message..." onkeypress="if(event.key==='Enter')sendMsg()">
        <button onclick="sendMsg()">Send</button>
        <button onclick="sendPing()">Ping</button>
    </div>
    <script>
        let ws = null;
        function connect() {
            if (ws && ws.readyState === WebSocket.OPEN) return;
            const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
            ws = new WebSocket(protocol + '//' + location.host + '/ws');
            ws.onopen = function() {
                document.getElementById('status').className = 'connected';
                document.getElementById('status').textContent = 'Connected';
                addMsg('system', 'Connected');
            };
            ws.onclose = function(e) {
                document.getElementById('status').className = 'disconnected';
                document.getElementById('status').textContent = 'Disconnected';
                addMsg('system', 'Disconnected');
                ws = null;
            };
            ws.onmessage = function(e) { addMsg('recv', e.data); };
        }
        function disconnect() { if (ws) { ws.close(); ws = null; } }
        function sendMsg() {
            const input = document.getElementById('msgInput');
            const msg = input.value.trim();
            if (!msg || !ws || ws.readyState !== WebSocket.OPEN) return;
            ws.send(msg);
            addMsg('sent', msg);
            input.value = '';
        }
        function sendPing() {
            if (!ws || ws.readyState !== WebSocket.OPEN) return;
            ws.send('/ping');
            addMsg('sent', '/ping');
        }
        function addMsg(type, text) {
            const messages = document.getElementById('messages');
            const div = document.createElement('div');
            div.className = 'msg';
            const time = new Date().toLocaleTimeString();
            let prefix = type === 'sent' ? '->' : type === 'recv' ? '<-' : '*';
            // Use textContent to escape user data
            const timeSpan = document.createElement('span');
            timeSpan.className = 'msg-time';
            timeSpan.textContent = '[' + time + ']';
            const msgSpan = document.createElement('span');
            msgSpan.className = 'msg-' + type;
            msgSpan.textContent = prefix + ' ' + text;
            div.appendChild(timeSpan);
            div.appendChild(document.createTextNode(' '));
            div.appendChild(msgSpan);
            messages.appendChild(div);
            messages.scrollTop = messages.scrollHeight;
            while (messages.children.length > 50) messages.removeChild(messages.firstChild);
        }
        connect();
    </script>
</body>
</html>
HTML

sub send_ws_message {
    my ($client, $msg) = @_;
    return unless $client && $client->{io};
    my $frame = Protocol::WebSocket::Frame->new(type => 'text', buffer => $msg);
    eval { syswrite($client->{io}, $frame->to_bytes) };
    delete $clients{$client->{id}} if $@;
}

sub handle_message {
    my ($client, $msg) = @_;
    if ($msg eq '/ping') {
        send_ws_message($client, "pong! (time: " . time() . ")");
    }
    elsif ($msg =~ m{^/broadcast\s+(.+)}) {
        my $text = $1;
        send_ws_message($_, "Broadcast from #$client->{id}: $text") for values %clients;
    }
    else {
        send_ws_message($client, "Echo: $msg");
    }
}

# PSGI app
my $app = sub {
    my $env = shift;
    my $path = $env->{PATH_INFO} || '/';

    if ($path eq '/' || $path eq '/index.html') {
        return [200, ['Content-Type' => 'text/html; charset=utf-8'], [$html_page]];
    }
    elsif ($path eq '/ws') {
        # Check for WebSocket upgrade
        my $upgrade = $env->{HTTP_UPGRADE} || '';
        unless (lc($upgrade) eq 'websocket') {
            return [400, ['Content-Type' => 'text/plain'], ['Expected WebSocket upgrade']];
        }

        # Get raw socket via psgix.io
        my $io = $env->{'psgix.io'};
        unless ($io) {
            return [500, ['Content-Type' => 'text/plain'], ['psgix.io not available']];
        }

        # WebSocket handshake
        my $hs = Protocol::WebSocket::Handshake::Server->new_from_psgi($env);
        $hs->parse('');
        unless ($hs->is_done) {
            return [400, ['Content-Type' => 'text/plain'], ['Invalid WebSocket handshake']];
        }

        # Send handshake response
        syswrite($io, $hs->to_string);

        # Setup WebSocket connection
        my $id = ++$client_id;
        my $frame = Protocol::WebSocket::Frame->new;
        my $client = { id => $id, io => $io, frame => $frame };
        $clients{$id} = $client;

        # Setup EV watcher
        require EV;
        my $watcher;
        $watcher = EV::io($io, EV::READ(), sub {
            my $buf;
            my $bytes = sysread($io, $buf, 8192);
            if (!defined $bytes || $bytes == 0) {
                delete $clients{$id};
                $watcher->stop;
                undef $watcher;
                close($io);
                return;
            }
            $frame->append($buf);
            while (defined(my $msg = $frame->next)) {
                if ($frame->is_close) {
                    my $close = Protocol::WebSocket::Frame->new(type => 'close')->to_bytes;
                    syswrite($io, $close);
                    delete $clients{$id};
                    $watcher->stop;
                    undef $watcher;
                    close($io);
                    return;
                }
                elsif ($frame->is_ping) {
                    my $pong = Protocol::WebSocket::Frame->new(type => 'pong', buffer => $msg)->to_bytes;
                    syswrite($io, $pong);
                }
                elsif ($frame->is_text) {
                    handle_message($client, $msg);
                }
            }
        });

        # Keepalive: periodic ping every 30s
        my $ping_w;
        $ping_w = EV::timer(30, 30, sub {
            unless ($clients{$id}) {
                undef $ping_w;
                return;
            }
            my $ping = Protocol::WebSocket::Frame->new(type => 'ping', buffer => '')->to_bytes;
            eval { syswrite($io, $ping) };
            if ($@) {
                delete $clients{$id};
                undef $ping_w;
            }
        });

        # Send welcome
        send_ws_message($client, "Welcome! You are client #$id. Commands: /ping, /broadcast <msg>");

        # Return empty response (we've taken over the socket)
        return sub { };  # Streaming response that never calls responder
    }
    else {
        return [404, ['Content-Type' => 'text/plain'], ['Not Found']];
    }
};
