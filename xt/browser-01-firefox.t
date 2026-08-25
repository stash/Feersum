#!perl
# Extended test: real browser (Firefox via Marionette) over TLS + H2
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use POSIX qw(_exit);
use Digest::SHA1 qw(sha1_base64);
use Compress::Raw::Zlib qw(Z_SYNC_FLUSH Z_OK MAX_WBITS);
use JSON::PP;

my $HAS_WSEVX = eval { require Net::WebSocket::EVx; 1 };
use constant {
    WS_GUID          => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11',
    WS_DEFLATE_TAIL  => pack(C4 => 0, 0, 255, 255),
};

eval { require Firefox::Marionette; require Firefox::Marionette::Capabilities }
    or plan skip_all => "Firefox::Marionette not installed";

my $evh = Feersum->new_instance();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;

my ($socket, $port) = get_listen_socket();
my ($socket_h1, $port_h1) = get_listen_socket();
my ($socket_psgi, $port_psgi) = get_listen_socket();

plan tests => 3;

ok $socket, "got listen sockets: H2=$port H1=$port_h1 PSGI=$port_psgi";

my $pid = fork // die "fork: $!";

if ($pid == 0) {
    Test::More->builder->no_ending(1);
    sleep 1;

    my $pass = 0;
    my $fail = 0;
    my $test = sub {
        my ($ok, $name) = @_;
        if ($ok) { $pass++; print STDERR "# PASS: $name\n" }
        else     { $fail++; print STDERR "# FAIL: $name\n" }
    };

    eval {
        my $caps = Firefox::Marionette::Capabilities->new(
            accept_insecure_certs => 1,
        );
        my $firefox = Firefox::Marionette->new(
            visible      => 0,
            implicit      => 5,
            capabilities => $caps,
        );
        $test->(1, "Firefox started");

        my $base    = "https://localhost:$port";
        my $base_h1 = "https://localhost:$port_h1";
        my $base_psgi = "https://localhost:$port_psgi";

        # ----- basic responses -----

        # plain text
        $firefox->go("$base/hello");
        my $body = $firefox->strip();
        $test->($body =~ /Hello, World/, "GET /hello - plain text");

        # HTML
        $firefox->go("$base/html");
        $test->($firefox->title() eq "Feersum Test", "GET /html - page title");
        $test->($firefox->find_tag('h1')->text() eq "It Works!", "GET /html - h1 content");

        # JSON
        $firefox->go("$base/json");
        $body = $firefox->strip();
        $test->($body =~ /"server"\s*:\s*"Feersum"/, "GET /json - JSON response");

        # large streaming
        $firefox->go("$base/large");
        $body = $firefox->strip();
        my $len = length($body);
        $test->($len >= 50000, "GET /large - streaming ($len bytes)");

        # fetch API header check
        my $hdr = $firefox->script(qq{
            return fetch("$base/hello").then(r => r.headers.get("X-Server"));
        }, sandbox => 'default', new => 1, args => []);
        $test->($hdr eq "Feersum", "X-Server header via fetch()");

        # ----- Server-Sent Events -----

        my $sse_result = $firefox->script(qq{
            return new Promise((resolve, reject) => {
                let events = [];
                let es = new EventSource("$base/events");
                es.onmessage = function(e) {
                    events.push(e.data);
                    if (events.length >= 5) {
                        es.close();
                        resolve(JSON.stringify(events));
                    }
                };
                es.onerror = function(e) {
                    if (events.length >= 5) return;
                    es.close();
                    reject("SSE error after " + events.length + " events");
                };
                setTimeout(() => { es.close(); reject("SSE timeout after " + events.length + " events"); }, 10000);
            });
        }, sandbox => 'default', new => 1, args => []);
        print STDERR "# SSE result: $sse_result\n";
        my $sse_events = JSON::PP::decode_json($sse_result);
        $test->(scalar @$sse_events == 5, "SSE - received 5 events via EventSource");

        my $content_ok = 1;
        for my $i (0..4) {
            $content_ok = 0 unless $sse_events->[$i] eq "event-" . ($i + 1);
        }
        $test->($content_ok, "SSE - events have correct sequential data");

        # ----- HTTP/2 negotiation -----

        my $proto = $firefox->script(qq{
            let e = performance.getEntriesByType("navigation")[0];
            return e ? e.nextHopProtocol : "unknown";
        }, sandbox => 'default', new => 1, args => []);
        print STDERR "# negotiated protocol: $proto\n";
        $test->($proto eq "h2", "HTTP/2 negotiated via ALPN ($proto)");

        # navigate to reset page state before fetch-based tests
        $firefox->go("$base/html");

        # ----- POST body -----

        my $post_result = $firefox->script(qq{
            return fetch("$base/echo", {
                method: "POST",
                headers: {"Content-Type": "text/plain"},
                body: "hello from browser"
            }).then(r => r.text());
        }, sandbox => 'default', new => 1, args => []);
        $test->($post_result eq "hello from browser", "POST /echo - body echoed");

        # ----- POST form data -----

        my $form_result = $firefox->script(qq{
            let fd = new URLSearchParams();
            fd.append("name", "feersum");
            fd.append("version", "42");
            return fetch("$base/form", {
                method: "POST",
                headers: {"Content-Type": "application/x-www-form-urlencoded"},
                body: fd.toString()
            }).then(r => r.text());
        }, sandbox => 'default', new => 1, args => []);
        my $form = JSON::PP::decode_json($form_result);
        $test->($form->{name} eq "feersum", "POST /form - form field 'name'");
        $test->($form->{version} eq "42", "POST /form - form field 'version'");

        # ----- multipart file upload -----

        my $upload_result = $firefox->script(qq{
            let blob = new Blob(["file content here"], {type: "text/plain"});
            let fd = new FormData();
            fd.append("field1", "value1");
            fd.append("file", blob, "test.txt");
            return fetch("$base/upload", {
                method: "POST",
                body: fd
            }).then(r => r.text());
        }, sandbox => 'default', new => 1, args => []);
        my $upload = JSON::PP::decode_json($upload_result);
        $test->($upload->{content_type} =~ m{^multipart/form-data},
                "POST /upload - multipart content type");
        $test->($upload->{body} =~ /file content here/,
                "POST /upload - file content in body");
        $test->($upload->{body} =~ /test\.txt/,
                "POST /upload - filename in body");

        # ----- HEAD request -----

        my $head_result = $firefox->script(qq{
            return fetch("$base/hello", {method: "HEAD"}).then(r => {
                return JSON.stringify({
                    status: r.status,
                    cl: r.headers.get("Content-Length"),
                    server: r.headers.get("X-Server"),
                    bodyLen: 0
                });
            }).then(async (meta) => {
                // HEAD should have empty body
                let r2 = await fetch("$base/hello", {method: "HEAD"});
                let body = await r2.text();
                let m = JSON.parse(meta);
                m.bodyLen = body.length;
                return JSON.stringify(m);
            });
        }, sandbox => 'default', new => 1, args => []);
        my $head = JSON::PP::decode_json($head_result);
        $test->($head->{status} == 200, "HEAD /hello - status 200");
        $test->($head->{server} eq "Feersum", "HEAD /hello - X-Server header");
        $test->($head->{bodyLen} == 0, "HEAD /hello - empty body");

        # ----- redirect chain -----

        my $redir_result = $firefox->script(qq{
            return fetch("$base/redirect/3", {redirect: "follow"}).then(async r => {
                let body = await r.text();
                return JSON.stringify({status: r.status, url: r.url, body: body});
            });
        }, sandbox => 'default', new => 1, args => []);
        my $redir = JSON::PP::decode_json($redir_result);
        $test->($redir->{status} == 200, "Redirect chain - final status 200");
        $test->($redir->{url} =~ /\/redirect\/0/, "Redirect chain - followed to /redirect/0");
        $test->($redir->{body} eq "done", "Redirect chain - final body");

        # ----- cookies -----

        my $cookie_result = $firefox->script(qq{
            return fetch("$base/set-cookie")
                .then(() => fetch("$base/get-cookie"))
                .then(r => r.text());
        }, sandbox => 'default', new => 1, args => []);
        $test->($cookie_result =~ /test_val=feersum42/,
                "Cookies - set and retrieved ($cookie_result)");

        # ----- range request -----

        my $range_result = $firefox->script(qq{
            return fetch("$base/range-data", {
                headers: {"Range": "bytes=5-14"}
            }).then(async r => {
                let body = await r.text();
                return JSON.stringify({
                    status: r.status,
                    cr: r.headers.get("Content-Range"),
                    body: body
                });
            });
        }, sandbox => 'default', new => 1, args => []);
        my $range = JSON::PP::decode_json($range_result);
        $test->($range->{status} == 206, "Range request - status 206");
        $test->($range->{cr} eq "bytes 5-14/26", "Range request - Content-Range header");
        $test->($range->{body} eq "fghijklmno", "Range request - correct byte range");

        # ----- CORS preflight -----
        # Page loaded from H2 port, fetch to H1 port = cross-origin

        $firefox->go("$base/html");  # ensure we're on H2 origin
        my $cors_result = $firefox->script(qq{
            return fetch("$base_h1/cors-test", {
                method: "PUT",
                headers: {"X-Custom": "test123", "Content-Type": "application/json"},
                body: '{"cross":"origin"}'
            }).then(async r => {
                let body = await r.text();
                return JSON.stringify({
                    status: r.status,
                    body: body,
                    custom: r.headers.get("X-Custom-Response")
                });
            });
        }, sandbox => 'default', new => 1, args => []);
        my $cors = JSON::PP::decode_json($cors_result);
        $test->($cors->{status} == 200, "CORS - cross-origin PUT status 200");
        $test->($cors->{body} eq '{"cross":"origin"}', "CORS - body echoed");
        $test->($cors->{custom} eq "allowed", "CORS - custom response header exposed");

        # ----- H2 multiplexing -----

        my $mux_result = $firefox->script(qq{
            let n = 50;
            let promises = [];
            for (let i = 0; i < n; i++) {
                promises.push(
                    fetch("$base/multiplex/" + i)
                        .then(r => r.text())
                        .then(body => ({i: i, body: body}))
                );
            }
            return Promise.all(promises).then(results => {
                let ok = results.every(r => r.body === "req-" + r.i);
                return JSON.stringify({count: results.length, allCorrect: ok});
            });
        }, sandbox => 'default', new => 1, args => []);
        my $mux = JSON::PP::decode_json($mux_result);
        $test->($mux->{count} == 50, "H2 multiplex - 50 concurrent requests completed");
        $test->($mux->{allCorrect}, "H2 multiplex - all responses matched their request");

        # ----- slow streaming (trickle) -----

        my $trickle_result = $firefox->script(qq{
            return fetch("$base/trickle").then(resp => {
                let reader = resp.body.getReader();
                let decoder = new TextDecoder();
                let chunks = [];
                function pump() {
                    return reader.read().then(({done, value}) => {
                        if (done) {
                            let full = chunks.join("");
                            let lines = full.trim().split("\\n");
                            return JSON.stringify({numChunks: chunks.length, numLines: lines.length, lines: lines});
                        }
                        chunks.push(decoder.decode(value, {stream: true}));
                        return pump();
                    });
                }
                return pump();
            });
        }, sandbox => 'default', new => 1, args => []);
        my $trickle = JSON::PP::decode_json($trickle_result);
        $test->($trickle->{numLines} == 5, "Slow streaming - received 5 lines");
        my $trickle_ok = 1;
        for my $i (0..4) {
            $trickle_ok = 0 unless $trickle->{lines}[$i] eq "tick-" . ($i + 1);
        }
        $test->($trickle_ok, "Slow streaming - correct trickle content");

        # ----- PSGI handler -----

        my $psgi_result = $firefox->script(qq{
            return fetch("$base_psgi/psgi-hello").then(r1 => {
                return r1.text().then(body1 => {
                    return fetch("$base_psgi/psgi-hello", {
                        method: "POST",
                        headers: {"Content-Type": "text/plain"},
                        body: "psgi post body"
                    }).then(r2 => r2.text().then(body2 => {
                        return JSON.stringify({
                            get_status: r1.status,
                            get_body: body1,
                            get_server: r1.headers.get("X-Handler"),
                            post_status: r2.status,
                            post_body: body2
                        });
                    }));
                });
            });
        }, sandbox => 'default', new => 1, args => []);
        my $psgi = JSON::PP::decode_json($psgi_result);
        $test->($psgi->{get_status} == 200, "PSGI - GET status 200");
        $test->($psgi->{get_body} eq "Hello from PSGI", "PSGI - GET body");
        $test->($psgi->{get_server} eq "psgi", "PSGI - X-Handler header");
        $test->($psgi->{post_status} == 200, "PSGI - POST status 200");
        $test->($psgi->{post_body} eq "psgi post body", "PSGI - POST body echoed");

        # ----- ETag / 304 Not Modified -----

        my $etag_result = $firefox->script(qq{
            return fetch("$base/etag-resource").then(r1 => {
                return r1.text().then(body1 => {
                    let etag = r1.headers.get("ETag");
                    return fetch("$base/etag-resource", {
                        headers: {"If-None-Match": etag}
                    }).then(r2 => {
                        return r2.text().then(body2 => {
                            return JSON.stringify({
                                first_status: r1.status,
                                first_body: body1,
                                etag: etag,
                                second_status: r2.status,
                                second_body: body2
                            });
                        });
                    });
                });
            });
        }, sandbox => 'default', new => 1, args => []);
        my $etag = JSON::PP::decode_json($etag_result);
        $test->($etag->{first_status} == 200, "ETag - first request 200");
        $test->($etag->{etag} eq '"feersum-v1"', "ETag - header present");
        $test->($etag->{second_status} == 304, "ETag - conditional request 304");
        $test->($etag->{second_body} eq '', "ETag - 304 has empty body");

        # ----- Content-Encoding: gzip -----

        my $gzip_result = $firefox->script(qq{
            return fetch("$base/gzipped").then(async r => {
                let body = await r.text();
                return JSON.stringify({
                    status: r.status,
                    body: body,
                    encoding: r.headers.get("Content-Encoding")
                });
            });
        }, sandbox => 'default', new => 1, args => []);
        my $gzip = JSON::PP::decode_json($gzip_result);
        $test->($gzip->{status} == 200, "Gzip - status 200");
        $test->($gzip->{body} eq "This content was gzip compressed by Feersum",
                "Gzip - browser decompressed correctly");

        # ----- AbortController (client disconnect) -----

        my $abort_result = $firefox->script(qq{
            let controller = new AbortController();
            let aborted = false;
            let fetchPromise = fetch("$base/slow-stream", {signal: controller.signal})
                .then(r => r.text())
                .catch(e => { aborted = true; return "aborted"; });
            // Abort after 200ms
            return new Promise(resolve => {
                setTimeout(() => {
                    controller.abort();
                    fetchPromise.then(result => {
                        resolve(JSON.stringify({aborted: aborted, result: result}));
                    });
                }, 200);
            });
        }, sandbox => 'default', new => 1, args => []);
        my $abort = JSON::PP::decode_json($abort_result);
        $test->($abort->{aborted}, "AbortController - fetch was aborted");
        $test->($abort->{result} eq "aborted", "AbortController - caught abort error");

        # ----- navigator.sendBeacon -----

        $firefox->go("$base/html");
        my $beacon_result = $firefox->script(qq{
            let ok = navigator.sendBeacon("$base/beacon", "beacon-payload");
            // Wait a bit for beacon to be processed
            return new Promise(resolve => {
                setTimeout(() => {
                    fetch("$base/beacon-check").then(r => r.text()).then(body => {
                        resolve(JSON.stringify({sent: ok, received: body}));
                    });
                }, 500);
            });
        }, sandbox => 'default', new => 1, args => []);
        my $beacon = JSON::PP::decode_json($beacon_result);
        $test->($beacon->{sent}, "sendBeacon - returned true");
        $test->($beacon->{received} eq "beacon-payload", "sendBeacon - server received payload");

        # ----- Performance API timing -----

        # Navigate first to get page context, then fetch and read perf entries
        $firefox->go("$base/html");
        my $perf_result = $firefox->script(qq{
            performance.clearResourceTimings();
            return fetch("$base/json").then(() => {
                // Small delay to let the entry register
                return new Promise(resolve => setTimeout(resolve, 100));
            }).then(() => {
                let entries = performance.getEntriesByType("resource")
                    .filter(e => e.name.includes("/json"));
                if (entries.length === 0) return JSON.stringify({ok: false});
                let e = entries[entries.length - 1];
                return JSON.stringify({
                    ok: true,
                    protocol: e.nextHopProtocol,
                    ttfb: Math.round(e.responseStart - e.requestStart),
                    duration: Math.round(e.duration),
                    transferSize: e.transferSize
                });
            });
        }, sandbox => 'system', new => 1, args => []);
        my $perf = JSON::PP::decode_json($perf_result);
        if ($perf->{ok}) {
            print STDERR "# Perf: protocol=$perf->{protocol} ttfb=$perf->{ttfb}ms " .
                         "duration=$perf->{duration}ms transfer=$perf->{transferSize}b\n";
            $test->($perf->{protocol} eq "h2", "Performance API - protocol is h2");
            $test->($perf->{duration} >= 0, "Performance API - duration measured");
        }
        else {
            print STDERR "# Perf: no entries found, skipping\n";
            $test->(0, "Performance API - protocol is h2");
            $test->(0, "Performance API - duration measured");
        }

        # ----- concurrent WebSocket + HTTP -----

        if ($HAS_WSEVX) {
            my $concurrent_result = $firefox->script(qq{
                return new Promise((resolve, reject) => {
                    let ws = new WebSocket("wss://localhost:$port/ws");
                    let wsReplies = [];
                    let httpResults = [];
                    ws.onopen = function() {
                        // Fire WS messages and HTTP fetches simultaneously
                        ws.send("concurrent-1");
                        ws.send("concurrent-2");
                        let p1 = fetch("$base/multiplex/100").then(r => r.text());
                        let p2 = fetch("$base/multiplex/101").then(r => r.text());
                        let p3 = fetch("$base/multiplex/102").then(r => r.text());
                        Promise.all([p1, p2, p3]).then(results => {
                            httpResults = results;
                            // Check if we already have both
                            if (wsReplies.length >= 2) finish();
                        });
                    };
                    ws.onmessage = function(e) {
                        wsReplies.push(e.data);
                        if (wsReplies.length >= 2 && httpResults.length >= 3) finish();
                    };
                    function finish() {
                        ws.close();
                        resolve(JSON.stringify({ws: wsReplies, http: httpResults}));
                    }
                    ws.onerror = function() { reject("concurrent WS error"); };
                    setTimeout(() => { ws.close(); reject("concurrent timeout"); }, 10000);
                });
            }, sandbox => 'default', new => 1, args => []);
            my $conc = JSON::PP::decode_json($concurrent_result);
            $test->(scalar @{$conc->{ws}} == 2, "Concurrent WS+HTTP - 2 WS replies");
            $test->($conc->{ws}[0] eq "echo:concurrent-1", "Concurrent WS+HTTP - WS reply 1");
            $test->(scalar @{$conc->{http}} == 3, "Concurrent WS+HTTP - 3 HTTP responses");
            $test->($conc->{http}[0] eq "req-100", "Concurrent WS+HTTP - HTTP resp correct");
        }
        else {
            print STDERR "# SKIP: concurrent WS+HTTP (no Net::WebSocket::EVx)\n";
        }

        # ----- large download backpressure -----

        my $bigdl_result = $firefox->script(qq{
            return fetch("$base/big-download").then(resp => {
                let reader = resp.body.getReader();
                let total = 0;
                function pump() {
                    return reader.read().then(({done, value}) => {
                        if (done) return JSON.stringify({size: total});
                        total += value.length;
                        return pump();
                    });
                }
                return pump();
            });
        }, sandbox => 'default', new => 1, args => []);
        my $bigdl = JSON::PP::decode_json($bigdl_result);
        my $expected_big = 2 * 1024 * 1024;  # 2MB
        $test->($bigdl->{size} == $expected_big,
                "Large download - received $bigdl->{size}/$expected_big bytes");

        # ----- WebSocket close codes -----

        if ($HAS_WSEVX) {
            # Small delay between WS tests
            $firefox->script(qq{ return new Promise(r => setTimeout(r, 200)); },
                sandbox => 'default', new => 1, args => []);
            my $ws_close_result = $firefox->script(qq{
                return new Promise((resolve, reject) => {
                    let ws = new WebSocket("wss://localhost:$port_h1/ws-close");
                    ws.onopen = function() {
                        ws.send("close-me");
                    };
                    ws.onclose = function(e) {
                        resolve(JSON.stringify({code: e.code, reason: e.reason, clean: e.wasClean}));
                    };
                    ws.onerror = function() { reject("WS close error"); };
                    setTimeout(() => { ws.close(); reject("WS close timeout"); }, 10000);
                });
            }, sandbox => 'default', new => 1, args => []);
            print STDERR "# WS close result: $ws_close_result\n";
            my $ws_close = JSON::PP::decode_json($ws_close_result);
            $test->($ws_close->{code} == 4000, "WebSocket close - custom code 4000");
            $test->($ws_close->{reason} eq "custom close", "WebSocket close - reason string");
        }
        else {
            print STDERR "# SKIP: WebSocket close codes (no Net::WebSocket::EVx)\n";
        }

        # ----- multiple Set-Cookie headers -----

        # Clear old cookies, set two via one response, verify via document.cookie
        $firefox->go("$base/clear-cookies");
        $firefox->go("$base/multi-cookie");
        my $multicookie_result = $firefox->script(qq{
            return document.cookie;
        }, sandbox => 'system', new => 1, args => []);
        print STDERR "# Multi-cookie: $multicookie_result\n";
        my $has_a = $multicookie_result =~ /cookie_a=alpha/;
        my $has_b = $multicookie_result =~ /cookie_b=beta/;
        $test->($has_a, "Multi Set-Cookie - cookie_a set");
        $test->($has_b, "Multi Set-Cookie - cookie_b set");

        # Verify server reads all cookies back via header('cookie')
        # Over H2, browser may split cookies into separate header entries
        my $server_cookies = $firefox->script(qq{
            return fetch("$base/get-cookie").then(r => r.text());
        }, sandbox => 'system', new => 1, args => []);
        print STDERR "# Server sees cookies: $server_cookies\n";
        my $srv_a = $server_cookies =~ /cookie_a=alpha/;
        my $srv_b = $server_cookies =~ /cookie_b=beta/;
        $test->($srv_a, "Multi Cookie - server header() sees cookie_a");
        $test->($srv_b, "Multi Cookie - server header() sees cookie_b");

        # ----- WebSocket echo (conditional on Net::WebSocket::EVx) -----

        if ($HAS_WSEVX) {
            my $ws_result = $firefox->script(qq{
                return new Promise((resolve, reject) => {
                    let ws = new WebSocket("wss://localhost:$port/ws");
                    let replies = [];
                    ws.onopen = function() {
                        ws.send("ping 1");
                        ws.send("ping 2");
                        ws.send("ping 3");
                    };
                    ws.onmessage = function(e) {
                        replies.push(e.data);
                        if (replies.length >= 3) {
                            ws.close();
                            resolve(JSON.stringify(replies));
                        }
                    };
                    ws.onerror = function(e) {
                        reject("WebSocket error after " + replies.length + " replies");
                    };
                    setTimeout(() => { ws.close(); reject("WebSocket timeout after " + replies.length + " replies"); }, 10000);
                });
            }, sandbox => 'default', new => 1, args => []);
            print STDERR "# WebSocket result: $ws_result\n";
            my $ws_msgs = JSON::PP::decode_json($ws_result);
            $test->(scalar @$ws_msgs == 3, "WebSocket - received 3 echo replies");

            my $ws_content_ok = 1;
            for my $i (0..2) {
                $ws_content_ok = 0 unless $ws_msgs->[$i] eq "echo:ping " . ($i + 1);
            }
            $test->($ws_content_ok, "WebSocket - echo content correct");

            # Binary WebSocket (use H1 port for clean H1 WS)
            # Server /ws-bin echoes raw binary; we send 256 bytes and get hex digest back
            # via a second text message from the server that confirms receipt
            my $ws_bin_result = $firefox->script(qq{
                return new Promise((resolve, reject) => {
                    let ws = new WebSocket("wss://localhost:$port_h1/ws-bin");
                    ws.onopen = function() {
                        // Send as text: hex-encoded binary bytes 0-255
                        let hex = "";
                        for (let i = 0; i < 256; i++) hex += String.fromCharCode(i);
                        ws.send(hex);
                    };
                    ws.onmessage = function(e) {
                        // Server echoes back the same data as text
                        let data = e.data;
                        let ok = data.length === 256;
                        for (let i = 0; i < 256 && ok; i++) {
                            if (data.charCodeAt(i) !== i) ok = false;
                        }
                        ws.close();
                        resolve(JSON.stringify({size: data.length, ok: ok}));
                    };
                    ws.onerror = function() { reject("WS binary error"); };
                    setTimeout(() => { ws.close(); reject("WS binary timeout"); }, 10000);
                });
            }, sandbox => 'default', new => 1, args => []);
            print STDERR "# WS binary result: $ws_bin_result\n";
            my $ws_bin = JSON::PP::decode_json($ws_bin_result);
            $test->($ws_bin->{size} == 256, "WebSocket binary - 256 chars echoed");
            $test->($ws_bin->{ok}, "WebSocket binary - char codes 0-255 round-tripped");

            # WebSocket with permessage-deflate compression (over H1 TLS)
            # Retry: previous WS connection on H1 port may still be draining
            my $ws_deflate_result = $firefox->script(qq{
                function attempt() {
                    return new Promise((resolve, reject) => {
                        let ws = new WebSocket("wss://localhost:$port_h1/ws");
                        let replies = [];
                        let ext = "";
                        ws.onopen = function() {
                            ext = ws.extensions;
                            ws.send("ABCDEFGH".repeat(500));
                            ws.send("small msg");
                        };
                        ws.onmessage = function(e) {
                            replies.push(e.data);
                            if (replies.length >= 2) {
                                ws.close();
                                resolve(JSON.stringify({ext: ext, msgs: replies}));
                            }
                        };
                        ws.onerror = function() { reject("retry"); };
                        setTimeout(() => { ws.close(); reject("retry"); }, 5000);
                    });
                }
                function tryWithRetry(n) {
                    return attempt().catch(e => {
                        if (n > 0) return new Promise(r => setTimeout(r, 300)).then(() => tryWithRetry(n - 1));
                        throw "WS deflate failed after retries";
                    });
                }
                return tryWithRetry(3);
            }, sandbox => 'default', new => 1, args => []);
            print STDERR "# WS deflate result (truncated): ext=" .
                (eval { JSON::PP::decode_json($ws_deflate_result)->{ext} } || '') . "\n";
            my $ws_d = JSON::PP::decode_json($ws_deflate_result);
            my $ext = $ws_d->{ext} || '';
            $test->($ext =~ /permessage-deflate/,
                    "WebSocket deflate - permessage-deflate negotiated ($ext)");
            $test->(scalar @{$ws_d->{msgs}} == 2, "WebSocket deflate - received 2 replies");
            $test->($ws_d->{msgs}[0] eq "echo:" . ("ABCDEFGH" x 500),
                    "WebSocket deflate - large message echoed correctly");
            $test->($ws_d->{msgs}[1] eq "echo:small msg",
                    "WebSocket deflate - small message echoed correctly");
        }
        else {
            print STDERR "# SKIP: Net::WebSocket::EVx not installed\n";
        }

        $firefox->quit();
    };
    if ($@) {
        print STDERR "# Browser error: $@\n";
        $fail++;
    }

    print STDERR "# Browser tests: $pass passed, $fail failed\n";
    _exit($fail ? 1 : 0);
}

# ===========================================================================
# Parent: Feersum servers
# ===========================================================================

# --- H2 server (main) ---
$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
if ($@) {
    diag "TLS setup failed: $@";
    kill 9, $pid;
    die;
}

# --- H1-only TLS server (for WS permessage-deflate, CORS target) ---
my $evh_h1 = Feersum->new_instance();
$evh_h1->use_socket($socket_h1);
eval { $evh_h1->set_tls(cert_file => $cert_file, key_file => $key_file) };
if ($@) {
    diag "H1 TLS setup failed: $@";
    kill 9, $pid;
    die;
}

# --- PSGI server ---
my $evh_psgi = Feersum->new_instance();
$evh_psgi->use_socket($socket_psgi);
eval { $evh_psgi->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
if ($@) {
    diag "PSGI TLS setup failed: $@";
    kill 9, $pid;
    die;
}

# ===========================================================================
# Static data for range requests
# ===========================================================================
my $range_data = "abcdefghijklmnopqrstuvwxyz";  # 26 bytes
my $beacon_data = '';

# ===========================================================================
# Helpers
# ===========================================================================
sub read_body {
    my $r = shift;
    my $input = $r->input;
    return '' unless $input;
    my $body = '';
    $input->read($body, $r->content_length || 0);
    $input->close;
    return $body;
}

sub ws_handshake {
    my ($r, $io, %opts) = @_;
    my $key = $r->header('sec-websocket-key') || '';
    my $accept = sha1_base64($key . WS_GUID) . '=';
    my $handshake = "HTTP/1.1 101 Switching Protocols\015\012" .
                    "Upgrade: websocket\015\012" .
                    "Connection: Upgrade\015\012" .
                    "Sec-WebSocket-Accept: $accept\015\012";
    $handshake .= "Sec-WebSocket-Extensions: permessage-deflate\015\012"
        if $opts{deflate};
    $handshake .= "\015\012";
    syswrite($io, $handshake);
}

sub ws_upgrade {
    my ($r, %opts) = @_;
    my $io = $r->io();
    unless ($io) {
        $r->send_response(500, ['Content-Type' => 'text/plain'], \"io() failed\n");
        return;
    }
    ws_handshake($r, $io, %opts);
    open(my $fh, '+<&', $io) or die "dup: $!";
    return ($io, $fh);
}


# ===========================================================================
# Native request handler (shared by H2 and H1 instances)
# ===========================================================================
my $handler = sub {
    my $r = shift;
    my $method = $r->method();
    my $path   = $r->path() || '/';

    # --- CORS preflight ---
    if ($method eq 'OPTIONS') {
        my $origin = $r->header('origin') || '*';
        $r->send_response(204, [
            'Access-Control-Allow-Origin'  => $origin,
            'Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers' => 'Content-Type, X-Custom',
            'Access-Control-Expose-Headers' => 'X-Custom-Response',
            'Access-Control-Max-Age'       => '3600',
        ], \'');
        return;
    }

    if ($path eq '/hello') {
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
            'X-Server'     => 'Feersum',
            'Content-Length' => 14,
        ], \"Hello, World!\n");
    }
    elsif ($path eq '/html') {
        my $html = <<'HTML';
<!DOCTYPE html>
<html><head><title>Feersum Test</title></head>
<body><h1>It Works!</h1><p>Served by Feersum with TLS.</p></body></html>
HTML
        $r->send_response(200, [
            'Content-Type' => 'text/html; charset=utf-8',
            'X-Server'     => 'Feersum',
        ], \$html);
    }
    elsif ($path eq '/json') {
        my $json = '{"server":"Feersum","tls":true,"status":"ok"}';
        $r->send_response(200, [
            'Content-Type' => 'application/json',
            'X-Server'     => 'Feersum',
        ], \$json);
    }
    elsif ($path eq '/echo') {
        my $body = read_body($r);
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
        ], \$body);
    }
    elsif ($path eq '/form') {
        my $body = read_body($r);
        my %params;
        for my $pair (split /&/, $body) {
            my ($k, $v) = split /=/, $pair, 2;
            $params{$k} = $v if defined $k;
        }
        my $json = JSON::PP::encode_json(\%params);
        $r->send_response(200, [
            'Content-Type' => 'application/json',
        ], \$json);
    }
    elsif ($path eq '/upload') {
        my $body = read_body($r);
        my $ct = $r->header('content-type') || '';
        my $json = JSON::PP::encode_json({
            content_type => $ct,
            body         => $body,
            length       => length($body),
        });
        $r->send_response(200, [
            'Content-Type' => 'application/json',
        ], \$json);
    }
    elsif ($path =~ m{^/redirect/(\d+)$}) {
        my $n = $1;
        if ($n > 0) {
            my $next = $n - 1;
            $r->send_response(302, [
                'Location'     => "/redirect/$next",
                'Content-Type' => 'text/plain',
            ], \"redirecting...\n");
        }
        else {
            $r->send_response(200, [
                'Content-Type' => 'text/plain',
            ], \"done");
        }
    }
    elsif ($path eq '/set-cookie') {
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
            'Set-Cookie'   => 'test_val=feersum42; Path=/',
        ], \"cookie set");
    }
    elsif ($path eq '/get-cookie') {
        my $cookie = $r->header('cookie') || 'none';
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
        ], \$cookie);
    }
    elsif ($path eq '/range-data') {
        my $range_hdr = $r->header('range') || '';
        if ($range_hdr =~ /bytes=(\d+)-(\d+)/) {
            my ($start, $end) = ($1, $2);
            $end = length($range_data) - 1 if $end >= length($range_data);
            my $slice = substr($range_data, $start, $end - $start + 1);
            my $total = length($range_data);
            $r->send_response(206, [
                'Content-Type'  => 'text/plain',
                'Content-Range' => "bytes $start-$end/$total",
                'Accept-Ranges' => 'bytes',
            ], \$slice);
        }
        else {
            $r->send_response(200, [
                'Content-Type'  => 'text/plain',
                'Accept-Ranges' => 'bytes',
            ], \$range_data);
        }
    }
    elsif ($path eq '/cors-test') {
        my $origin = $r->header('origin') || '*';
        my $body = read_body($r);
        $r->send_response(200, [
            'Content-Type'                  => 'text/plain',
            'Access-Control-Allow-Origin'   => $origin,
            'Access-Control-Expose-Headers' => 'X-Custom-Response',
            'X-Custom-Response'             => 'allowed',
        ], \$body);
    }
    elsif ($path =~ m{^/multiplex/(\d+)$}) {
        my $id = $1;
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
        ], \"req-$id");
    }
    elsif ($path eq '/trickle') {
        my $w = $r->start_streaming(200, [
            'Content-Type' => 'text/plain',
        ]);
        my $n = 0;
        my $t; $t = EV::timer(0.05, 0.05, sub {
            $n++;
            eval { $w->write("tick-$n\n") };
            if ($n >= 5) {
                undef $t;
                eval { $w->close() };
            }
        });
    }
    elsif ($path eq '/ws-bin' && $HAS_WSEVX) {
        my ($io, $fh) = ws_upgrade($r);
        return unless $io;
        my $ws; $ws = Net::WebSocket::EVx->new({
            fh          => $fh,
            on_msg_recv => sub {
                my ($rsv, $opcode, $msg, $status_code) = @_;
                $ws->queue_msg($msg, $opcode);
            },
            on_close => sub { undef $ws; undef $fh; undef $io },
        });
    }
    elsif ($path eq '/ws' && $HAS_WSEVX) {
        my $exts = $r->header('sec-websocket-extensions') || '';
        my $use_deflate = $exts =~ /permessage-deflate/;
        my ($deflate, $inflate);
        if ($use_deflate) {
            $deflate = Compress::Raw::Zlib::Deflate->new(WindowBits => -MAX_WBITS);
            $inflate = Compress::Raw::Zlib::Inflate->new(
                WindowBits => -MAX_WBITS, Bufsize => 1<<20, LimitOutput => 1,
            );
        }

        my ($io, $fh) = ws_upgrade($r, deflate => $use_deflate);
        return unless $io;
        my $ws; $ws = Net::WebSocket::EVx->new({
            fh          => $fh,
            on_msg_recv => sub {
                my ($rsv, $opcode, $msg, $status_code) = @_;
                my $reply = "echo:";
                if ($rsv && $inflate) {
                    # Decompress incoming
                    return unless $inflate->inflate(($msg .= WS_DEFLATE_TAIL), my $out) == Z_OK;
                    $reply .= $out;
                    # Compress outgoing
                    my $compressed;
                    return unless $deflate->deflate($reply, $compressed) == Z_OK
                              && $deflate->flush($compressed, Z_SYNC_FLUSH) == Z_OK;
                    substr $compressed, -4, 4, '';  # strip deflate tail
                    $ws->queue_msg_ex($compressed);
                }
                else {
                    $ws->queue_msg($reply . $msg, $opcode);
                }
            },
            on_close => sub { undef $_ for $ws, $fh, $io, $deflate, $inflate },
        });
    }
    elsif ($path eq '/etag-resource') {
        my $inm = $r->header('if-none-match') || '';
        if ($inm eq '"feersum-v1"') {
            $r->send_response(304, [
                'ETag' => '"feersum-v1"',
            ], \'');
        }
        else {
            $r->send_response(200, [
                'Content-Type' => 'text/plain',
                'ETag'         => '"feersum-v1"',
                'Cache-Control' => 'no-cache',
            ], \"etag content v1");
        }
    }
    elsif ($path eq '/gzipped') {
        require IO::Compress::Gzip;
        my $raw = "This content was gzip compressed by Feersum";
        my $compressed;
        IO::Compress::Gzip::gzip(\$raw, \$compressed)
            or die "gzip failed";
        $r->send_response(200, [
            'Content-Type'     => 'text/plain',
            'Content-Encoding' => 'gzip',
        ], \$compressed);
    }
    elsif ($path eq '/slow-stream') {
        my $w = $r->start_streaming(200, [
            'Content-Type' => 'text/plain',
        ]);
        my $n = 0;
        my $t; $t = EV::timer(0.1, 0.1, sub {
            $n++;
            eval { $w->write("slow-$n\n") };
            if ($n >= 50) {
                undef $t;
                eval { $w->close() };
            }
        });
    }
    elsif ($path eq '/beacon') {
        $beacon_data = read_body($r);
        $r->send_response(204, [], \'');
    }
    elsif ($path eq '/beacon-check') {
        my $data = $beacon_data || '';
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
        ], \$data);
    }
    elsif ($path eq '/big-download') {
        my $w = $r->start_streaming(200, [
            'Content-Type' => 'application/octet-stream',
        ]);
        # 2MB in 2KB chunks
        my $chunk = "X" x 2048;
        $w->write(\$chunk) for 1..1024;
        $w->close();
    }
    elsif ($path eq '/ws-close' && $HAS_WSEVX) {
        my ($io, $fh) = ws_upgrade($r);
        return unless $io;
        my $ws; $ws = Net::WebSocket::EVx->new({
            fh          => $fh,
            on_msg_recv => sub {
                my ($rsv, $opcode, $msg, $status_code) = @_;
                if ($msg eq 'close-me') {
                    $ws->close(4000, "custom close");
                }
            },
            on_close => sub { undef $ws; undef $fh; undef $io },
        });
    }
    elsif ($path eq '/clear-cookies') {
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
            'Set-Cookie'   => 'test_val=; Path=/; Max-Age=0',
            'Set-Cookie'   => 'cookie_a=; Path=/; Max-Age=0',
            'Set-Cookie'   => 'cookie_b=; Path=/; Max-Age=0',
        ], \"cookies cleared");
    }
    elsif ($path eq '/multi-cookie') {
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
            'Set-Cookie'   => 'cookie_a=alpha; Path=/',
            'Set-Cookie'   => 'cookie_b=beta; Path=/',
        ], \"cookies set");
    }
    elsif ($path eq '/events') {
        my $w = $r->start_streaming(200, [
            'Content-Type'  => 'text/event-stream',
            'Cache-Control' => 'no-cache',
        ]);
        my $n = 0;
        my $t; $t = EV::timer(0.05, 0.05, sub {
            $n++;
            eval { $w->write("data: event-$n\n\n") };
            if ($n >= 5) {
                undef $t;
                eval { $w->close() };
            }
        });
    }
    elsif ($path eq '/large') {
        my $w = $r->start_streaming(200, [
            'Content-Type' => 'text/plain',
            'X-Server'     => 'Feersum',
        ]);
        my $chunk = "x" x 1000 . "\n";
        $w->write(\$chunk) for 1..100;
        $w->close();
    }
    else {
        $r->send_response(404, ['Content-Type' => 'text/plain'], \"Not Found\n");
    }
};

$evh->request_handler($handler);
$evh_h1->request_handler($handler);

# ===========================================================================
# PSGI handler
# ===========================================================================
$evh_psgi->psgi_request_handler(sub {
    my $env = shift;
    my $path   = $env->{PATH_INFO} || '/';
    my $method = $env->{REQUEST_METHOD};
    my $origin = $env->{HTTP_ORIGIN} || '*';

    my @cors = (
        'Access-Control-Allow-Origin'  => $origin,
        'Access-Control-Allow-Methods' => 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers' => 'Content-Type',
        'Access-Control-Expose-Headers' => 'X-Handler',
    );

    if ($method eq 'OPTIONS') {
        return [204, \@cors, ['']];
    }
    elsif ($path eq '/psgi-hello' && $method eq 'GET') {
        return [200,
            ['Content-Type' => 'text/plain', 'X-Handler' => 'psgi', @cors],
            ["Hello from PSGI"]
        ];
    }
    elsif ($path eq '/psgi-hello' && $method eq 'POST') {
        my $input = $env->{'psgi.input'};
        my $body = '';
        $input->read($body, $env->{CONTENT_LENGTH} || 0);
        $input->close;
        return [200,
            ['Content-Type' => 'text/plain', 'X-Handler' => 'psgi', @cors],
            [$body]
        ];
    }
    else {
        return [404, ['Content-Type' => 'text/plain', @cors], ["Not Found"]];
    }
});

my $timeout = EV::timer(90, 0, sub {
    diag "timeout waiting for browser child";
    kill 9, $pid;
    EV::break();
});

my $child_status;
my $child_watch = EV::child($pid, 0, sub {
    my ($w, $revents) = @_;
    $child_status = $w->rstatus;
    EV::break();
});

ok 1, "servers started: H2=$port H1=$port_h1 PSGI=$port_psgi";

EV::run();

waitpid($pid, POSIX::WNOHANG());
$child_status //= $?;
is($child_status >> 8, 0, "browser tests all passed");
