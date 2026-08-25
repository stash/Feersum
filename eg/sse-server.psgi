#!perl
# Server-Sent Events (SSE) PSGI example
#
# Usage:
#   plackup -s Feersum eg/sse-server.psgi
#   # or
#   feersum --listen :5000 eg/sse-server.psgi
#
# Then open http://localhost:5000/ in your browser
#
use strict;
use warnings;

# Track connected SSE clients
my @clients;
my $client_id = 0;
my $event_id = 0;

# HTML page with SSE client
my $html_page = <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <title>Feersum SSE Demo (PSGI)</title>
    <style>
        body { font-family: monospace; padding: 20px; background: #1a1a2e; color: #eee; }
        h1 { color: #0f0; }
        #events { background: #16213e; padding: 15px; border-radius: 5px; max-height: 400px; overflow-y: auto; }
        .event { margin: 5px 0; padding: 5px; background: #0f3460; border-radius: 3px; }
        .event-time { color: #e94560; }
        .event-data { color: #0f0; }
        #status { margin: 10px 0; padding: 10px; border-radius: 5px; }
        .connected { background: #155724; }
        .disconnected { background: #721c24; }
        button { background: #e94560; color: white; border: none; padding: 10px 20px; cursor: pointer; border-radius: 5px; margin: 5px; }
        button:hover { background: #ff6b6b; }
    </style>
</head>
<body>
    <h1>Feersum SSE Demo (PSGI)</h1>
    <div id="status" class="disconnected">Disconnected</div>
    <button onclick="connect()">Connect</button>
    <button onclick="disconnect()">Disconnect</button>
    <h2>Events:</h2>
    <div id="events"></div>
    <script>
        let eventSource = null;
        function connect() {
            if (eventSource) return;
            eventSource = new EventSource('/events');
            eventSource.onopen = function() {
                document.getElementById('status').className = 'connected';
                document.getElementById('status').textContent = 'Connected';
            };
            eventSource.onerror = function() {
                document.getElementById('status').className = 'disconnected';
                document.getElementById('status').textContent = 'Disconnected';
                eventSource = null;
            };
            eventSource.onmessage = function(e) { addEvent('message', e.data, e.lastEventId); };
            eventSource.addEventListener('tick', function(e) { addEvent('tick', e.data, e.lastEventId); });
        }
        function disconnect() {
            if (eventSource) { eventSource.close(); eventSource = null;
                document.getElementById('status').className = 'disconnected';
                document.getElementById('status').textContent = 'Disconnected';
            }
        }
        function addEvent(type, data, id) {
            const events = document.getElementById('events');
            const div = document.createElement('div');
            div.className = 'event';
            const time = new Date().toLocaleTimeString();
            // Use textContent to escape user data
            const timeSpan = document.createElement('span');
            timeSpan.className = 'event-time';
            timeSpan.textContent = '[' + time + ']';
            const typeB = document.createElement('b');
            typeB.textContent = type;
            const dataSpan = document.createElement('span');
            dataSpan.className = 'event-data';
            dataSpan.textContent = data;
            div.appendChild(timeSpan);
            div.appendChild(document.createTextNode(' '));
            div.appendChild(typeB);
            div.appendChild(document.createTextNode(' (id:' + id + '): '));
            div.appendChild(dataSpan);
            events.insertBefore(div, events.firstChild);
            while (events.children.length > 50) events.removeChild(events.lastChild);
        }
        connect();
    </script>
</body>
</html>
HTML

# Setup timers on first request (when EV is available)
my $timers_setup = 0;
my ($tick, $tick_timer);

sub setup_timers {
    return if $timers_setup;
    $timers_setup = 1;

    require EV;
    $tick = 0;
    $tick_timer = EV::timer(1, 2, sub {
        $tick++;
        broadcast('tick', "Tick #$tick at " . localtime());
    });
}

sub broadcast {
    my ($event, $data) = @_;
    my $id = ++$event_id;
    my $msg = "";
    $msg .= "id: $id\n";
    $msg .= "event: $event\n" if $event && $event ne 'message';
    $msg .= "data: $data\n\n";

    @clients = grep {
        my $c = $_;
        if ($c->{writer}) {
            my $ok = eval { $c->{writer}->write($msg); 1 };
            $ok ? 1 : 0;
        } else { 0 }
    } @clients;
}

# PSGI app
my $app = sub {
    my $env = shift;
    my $path = $env->{PATH_INFO} || '/';

    setup_timers();

    if ($path eq '/' || $path eq '/index.html') {
        return [200, ['Content-Type' => 'text/html; charset=utf-8'], [$html_page]];
    }
    elsif ($path eq '/events') {
        # SSE streaming response
        return sub {
            my $responder = shift;
            my $writer = $responder->([200, [
                'Content-Type'  => 'text/event-stream',
                'Cache-Control' => 'no-cache',
                'X-Accel-Buffering' => 'no',
            ]]);

            my $id = ++$client_id;
            push @clients, { id => $id, writer => $writer };

            # Send welcome
            $writer->write("id: " . ++$event_id . "\ndata: Connected as client $id\n\n");
        };
    }
    else {
        return [404, ['Content-Type' => 'text/plain'], ['Not Found']];
    }
};
