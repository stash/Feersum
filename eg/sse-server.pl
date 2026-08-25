#!/usr/bin/env perl
# Server-Sent Events (SSE) example with Feersum
#
# Usage:
#   perl eg/sse-server.pl
#   perl eg/sse-server.pl --tls-cert-file eg/ssl-proxy/server.crt --tls-key-file eg/ssl-proxy/server.key
#
# Then open http://localhost:5000/ (or https://...) in your browser
#
use strict;
use warnings;
use EV;
use Feersum;
use IO::Socket::INET;
use Getopt::Long;

my $PORT = $ENV{PORT} || 5000;
my ($tls_cert, $tls_key);
GetOptions(
    'port=i'          => \$PORT,
    'tls-cert-file=s' => \$tls_cert,
    'tls-key-file=s'  => \$tls_key,
);

# Track connected SSE clients
my @clients;
my $client_id = 0;
my $event_id = 0;

# HTML page with SSE client
my $html_page = <<'HTML';
<!DOCTYPE html>
<html>
<head>
    <title>Feersum SSE Demo</title>
    <style>
        body { font-family: monospace; padding: 20px; background: #1a1a2e; color: #eee; }
        h1 { color: #0f0; }
        #events {
            background: #16213e;
            padding: 15px;
            border-radius: 5px;
            max-height: 400px;
            overflow-y: auto;
        }
        .event { margin: 5px 0; padding: 5px; background: #0f3460; border-radius: 3px; }
        .event-time { color: #e94560; }
        .event-data { color: #0f0; }
        #status { margin: 10px 0; padding: 10px; border-radius: 5px; }
        .connected { background: #155724; }
        .disconnected { background: #721c24; }
        button {
            background: #e94560;
            color: white;
            border: none;
            padding: 10px 20px;
            cursor: pointer;
            border-radius: 5px;
            margin: 5px;
        }
        button:hover { background: #ff6b6b; }
    </style>
</head>
<body>
    <h1>Feersum Server-Sent Events Demo</h1>
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

            // Handle 'message' event (default)
            eventSource.onmessage = function(e) {
                addEvent('message', e.data, e.lastEventId);
            };

            // Handle custom 'tick' event
            eventSource.addEventListener('tick', function(e) {
                addEvent('tick', e.data, e.lastEventId);
            });

            // Handle custom 'stats' event
            eventSource.addEventListener('stats', function(e) {
                addEvent('stats', e.data, e.lastEventId);
            });
        }

        function disconnect() {
            if (eventSource) {
                eventSource.close();
                eventSource = null;
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
            // Keep only last 50 events
            while (events.children.length > 50) {
                events.removeChild(events.lastChild);
            }
        }

        // Auto-connect on load
        connect();
    </script>
</body>
</html>
HTML

# Create listen socket
my $sock = IO::Socket::INET->new(
    LocalAddr => "0.0.0.0:$PORT",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => 1024,
    Blocking  => 0,
) or die "Cannot create socket: $!";

my $feersum = Feersum->endjinn;
$feersum->use_socket($sock);

my $scheme = 'http';
if ($tls_cert && $tls_key) {
    $feersum->set_tls(cert_file => $tls_cert, key_file => $tls_key, h2 => 1);
    $scheme = 'https';
}

print "SSE server listening on $scheme://localhost:$PORT/\n";

# Request handler
$feersum->request_handler(sub {
    my $req = shift;
    my $path = $req->env->{PATH_INFO};

    if ($path eq '/' || $path eq '/index.html') {
        # Serve HTML page
        $req->send_response(200, [
            'Content-Type' => 'text/html; charset=utf-8',
            'Cache-Control' => 'no-cache',
        ], \$html_page);
    }
    elsif ($path eq '/events') {
        # SSE endpoint
        start_sse_stream($req);
    }
    else {
        $req->send_response(404, ['Content-Type' => 'text/plain'], \"Not Found\n");
    }
});

sub start_sse_stream {
    my $req = shift;
    my $id = ++$client_id;

    # Start streaming with SSE headers
    my $w = $req->start_streaming(200, [
        'Content-Type'  => 'text/event-stream',
        'Cache-Control' => 'no-cache',
        'Connection'    => 'keep-alive',
        'X-Accel-Buffering' => 'no',  # Disable nginx buffering
    ]);

    # Store client info
    my $client = {
        id     => $id,
        writer => $w,
    };
    push @clients, $client;

    print "Client $id connected (total: " . scalar(@clients) . ")\n";

    # Send initial connection event
    send_sse_event($w, 'message', "Connected as client $id", ++$event_id);
}

sub send_sse_event {
    my ($writer, $event, $data, $id) = @_;
    return unless $writer;

    # SSE format: id, event, data fields followed by blank line
    my $msg = "";
    $msg .= "id: $id\n" if defined $id;
    $msg .= "event: $event\n" if $event && $event ne 'message';
    $msg .= "data: $data\n";
    $msg .= "\n";  # End of event

    eval { $writer->write($msg) };
    return !$@;
}

sub broadcast {
    my ($event, $data) = @_;
    my $id = ++$event_id;

    # Clean up dead clients and broadcast
    @clients = grep {
        my $c = $_;
        if ($c->{writer}) {
            my $ok = send_sse_event($c->{writer}, $event, $data, $id);
            if (!$ok) {
                print "Client $c->{id} disconnected\n";
                0;
            } else {
                1;
            }
        } else {
            0;
        }
    } @clients;
}

# Timer to send periodic events
my $tick = 0;
my $tick_timer = EV::timer 1, 2, sub {
    $tick++;
    broadcast('tick', "Tick #$tick at " . localtime());
};

# Timer to send stats every 5 seconds
my $stats_timer = EV::timer 5, 5, sub {
    my $count = scalar(grep { $_->{writer} } @clients);
    broadcast('stats', "Connected clients: $count, Total events: $event_id");
};

# Run event loop
EV::run;
