#!perl
# EV::Websockets browser integration test.
# Server and browser run in separate forks; parent orchestrates via pipes.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use POSIX qw(_exit);
use JSON::PP;

eval { require EV::Websockets }
    or plan skip_all => "EV::Websockets not installed";

eval { require Firefox::Marionette; require Firefox::Marionette::Capabilities }
    or plan skip_all => "Firefox::Marionette not installed";

my $evh = Feersum->new_instance();
plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();
undef $evh;

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;

my ($socket, $port) = get_listen_socket();

plan tests => 3;

ok $socket, "got listen socket on port $port";

# Readiness pipe: server child writes "R" when ready
pipe(my $ready_rd, my $ready_wr) or die "pipe: $!";

# ===========================================================================
# Server child: Feersum + EV::Websockets in isolated process
# ===========================================================================
my $srv_pid = fork // die "fork server: $!";
if ($srv_pid == 0) {
    close $ready_rd;

    my $srv = Feersum->new_instance();
    $srv->use_socket($socket);
    # No h2: lws adopt writes HTTP/1.1 framing (101 Switching Protocols)
    # which is incompatible with H2 Extended CONNECT data frames.
    $srv->set_tls(cert_file => $cert_file, key_file => $key_file);
    $srv->set_keepalive(1);

    my $ctx = EV::Websockets::Context->new(ssl_init => 0);

    $srv->request_handler(sub {
        my $r = shift;
        my $upgrade = $r->header('upgrade') // '';
        unless ($upgrade =~ /websocket/i) {
            $r->send_response(200, ['Content-Type' => 'text/plain'], \"hello-ok");
            return;
        }
        my $cookie = $r->header('cookie') || '';
        my $raw = $r->method() . " " . $r->uri() . " " . $r->protocol() . "\015\012";
        my $hdrs = $r->headers(0);
        while (my ($k, $v) = each %$hdrs) { $raw .= "$k: $v\015\012" }
        $raw .= "\015\012";
        my $io = $r->io() or return;
        $ctx->adopt(
            fh           => $io,
            initial_data => $raw,
            on_connect   => sub {},
            on_message   => sub {
                my ($c, $data) = @_;
                if ($data =~ /^echo:(.*)$/s) { $c->send("lws-echo:$1") }
                elsif ($data =~ /^close:(\d+):(.*)$/) { $c->close($1, $2) }
                elsif ($data eq 'get-cookies') { $c->send("lws-cookies:$cookie") }
                else { $c->send("lws-echo:$data") }
            },
            on_close => sub {}, on_error => sub {},
        );
    });

    syswrite($ready_wr, "R", 1);
    close $ready_wr;
    EV::run();
    _exit(0);
}
close $ready_wr;

# ===========================================================================
# Browser child: Firefox tests
# ===========================================================================
my $browser_pid = fork // die "fork browser: $!";
if ($browser_pid == 0) {
    Test::More->builder->no_ending(1);

    # Wait for server readiness
    vec(my $rin = '', fileno($ready_rd), 1) = 1;
    select($rin, undef, undef, 5);
    close $ready_rd;

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
            implicit     => 5,
            capabilities => $caps,
        );
        $test->(1, "Firefox started");

        my $base = "https://localhost:$port";

        # Basic HTTP over TLS
        $firefox->go("$base/hello");
        my $body = $firefox->strip();
        $test->($body =~ /hello-ok/, "HTTP over TLS works");

        # WebSocket via EV::Websockets adopt
        my $ws_result = $firefox->script(qq{
            function attempt() {
                return new Promise((resolve, reject) => {
                    let ws = new WebSocket("wss://localhost:$port/ws");
                    let results = {};
                    let step = 0;
                    ws.onopen = function() {
                        results.extensions = ws.extensions;
                        ws.send("echo:hello lws");
                    };
                    ws.onmessage = function(e) {
                        step++;
                        if (step === 1) {
                            results.echo = e.data;
                            ws.send("echo:" + "Z".repeat(65536));
                        } else if (step === 2) {
                            results.large_len = e.data.length;
                            results.large_ok = e.data === "lws-echo:" + "Z".repeat(65536);
                            ws.send("get-cookies");
                        } else if (step === 3) {
                            results.cookies = e.data.replace("lws-cookies:", "");
                            ws.send("close:4001:lws-bye");
                        }
                    };
                    ws.onclose = function(e) {
                        results.close_code = e.code;
                        results.close_reason = e.reason;
                        resolve(JSON.stringify(results));
                    };
                    ws.onerror = function() { reject("retry"); };
                    setTimeout(() => { ws.close(); reject("retry"); }, 5000);
                });
            }
            function tryWithRetry(n) {
                return attempt().catch(e => {
                    if (n > 0) return new Promise(r => setTimeout(r, 500)).then(() => tryWithRetry(n-1));
                    throw "EV::Websockets failed after retries";
                });
            }
            return tryWithRetry(3);
        }, sandbox => 'default', new => 1, args => []);

        print STDERR "# EV::Websockets: $ws_result\n";
        my $r = JSON::PP::decode_json($ws_result);
        $test->($r->{echo} eq "lws-echo:hello lws", "EV::Websockets - text echo");
        $test->(($r->{large_len} || 0) == 65536 + 9, "EV::Websockets - 64KB round-trip");
        $test->($r->{close_code} == 4001, "EV::Websockets - close code 4001");
        $test->($r->{close_reason} eq "lws-bye", "EV::Websockets - close reason");

        my $lws_ext = $r->{extensions} || '';
        my $lws_cookies = $r->{cookies} || '';
        print STDERR "# ext='$lws_ext' cookies='$lws_cookies'\n";

        $firefox->quit();
    };
    if ($@) {
        print STDERR "# Browser error: $@\n";
        $fail++;
    }

    print STDERR "# Browser tests: $pass passed, $fail failed\n";
    _exit($fail ? 1 : 0);
}
close $ready_rd;

# ===========================================================================
# Parent: orchestrate via EV child watchers
# ===========================================================================
ok 1, "server (pid=$srv_pid) + browser (pid=$browser_pid) forked";

my $child_status;
my $timeout = EV::timer(90, 0, sub {
    diag "timeout";
    kill 9, $browser_pid;
    kill POSIX::SIGQUIT(), $srv_pid;
    EV::break();
});

my $browser_watch = EV::child($browser_pid, 0, sub {
    my ($w) = @_;
    $child_status = $w->rstatus;
    kill POSIX::SIGQUIT(), $srv_pid;
    EV::break();
});

EV::run();

waitpid($srv_pid, 0);
waitpid($browser_pid, POSIX::WNOHANG());
$child_status //= $?;
is($child_status >> 8, 0, "browser tests all passed");
