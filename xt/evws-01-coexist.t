#!perl
# Test EV::Websockets context coexistence with Feersum on the same EV loop.
# Investigates: does eager EV::Websockets::Context->new(ssl_init => 0) break Feersum's
# accept loop, or must it be lazy-initialized after EV::run() starts?
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

eval { require EV::Websockets }
    or plan skip_all => "EV::Websockets not installed";

my $evh_test = Feersum->new_instance();
plan skip_all => "Feersum not compiled with TLS support"
    unless $evh_test->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;

use POSIX qw(_exit);
plan tests => 19;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

my $evh = Feersum->new_instance();
$evh->use_socket($socket);

# ---------------------------------------------------------------
# Test 1: Create EV::Websockets context BEFORE request_handler
# ---------------------------------------------------------------
my $ctx_early;
eval { $ctx_early = EV::Websockets::Context->new(ssl_init => 0) };
ok !$@, "EV::Websockets::Context->new(ssl_init => 0) before handler: no crash"
    or diag "Error: $@";

$evh->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"ok");
});

# Test: can Feersum still accept connections with lws context active?
{
    my $cv = AE::cv;
    my $response = '';

    my $h = AnyEvent::Handle->new(
        connect  => ['localhost', $port],
        on_error => sub { $cv->send("error: $_[2]") },
        on_eof   => sub { $cv->send("eof") },
    );
    $h->push_write("GET /test1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { $response .= $_[0]{rbuf}; $_[0]{rbuf} = '' });

    my $timer = AE::timer(3, 0, sub { $cv->send("timeout") });
    my $reason = $cv->recv;

    isnt $reason, "timeout", "request did not timeout with early ctx";
    like $response, qr/^HTTP\/1\.1 200/, "got 200 response with early ctx";
}

# ---------------------------------------------------------------
# Test 2: Create context AFTER Feersum is accepting
# ---------------------------------------------------------------
my $ctx_late;
eval { $ctx_late = EV::Websockets::Context->new(ssl_init => 0) };
ok !$@, "EV::Websockets::Context->new(ssl_init => 0) after handler: no crash"
    or diag "Error: $@";

{
    my $cv = AE::cv;
    my $response = '';

    my $h = AnyEvent::Handle->new(
        connect  => ['localhost', $port],
        on_error => sub { $cv->send("error: $_[2]") },
        on_eof   => sub { $cv->send("eof") },
    );
    $h->push_write("GET /test2 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { $response .= $_[0]{rbuf}; $_[0]{rbuf} = '' });

    my $timer = AE::timer(3, 0, sub { $cv->send("timeout") });
    my $reason = $cv->recv;

    isnt $reason, "timeout", "request did not timeout with late ctx";
    like $response, qr/^HTTP\/1\.1 200/, "got 200 response with late ctx";
}

# ---------------------------------------------------------------
# Test 3: Multiple contexts
# ---------------------------------------------------------------
my $ctx3;
eval { $ctx3 = EV::Websockets::Context->new(ssl_init => 0) };
ok !$@, "third context: no crash" or diag "Error: $@";

# Clean up plain-HTTP contexts before TLS tests (accumulated watchers starve TLS accept)
undef $ctx_early;
undef $ctx_late;
undef $ctx3;

# ---------------------------------------------------------------
# Test 4: TLS + H2 server with eager EV::Websockets context
# (reproduces the browser test failure scenario)
# ---------------------------------------------------------------
my ($tls_socket, $tls_port) = get_listen_socket();
ok $tls_socket, "got TLS listen socket on port $tls_port";

my $evh_tls = Feersum->new_instance();
$evh_tls->use_socket($tls_socket);
eval { $evh_tls->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

# Create ANOTHER lws context after TLS setup
my $ctx_tls;
eval { $ctx_tls = EV::Websockets::Context->new(ssl_init => 0) };
ok !$@, "context after TLS setup: no crash" or diag "Error: $@";

$evh_tls->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"tls-ok");
});

# Test: TLS connection still works? (forked client - server needs EV loop for TLS handshake)
SKIP: {
    eval { require IO::Socket::SSL };
    skip "IO::Socket::SSL not available", 2 if $@;
    skip "OpenSSL too old for TLS 1.3", 2 unless tls_client_ok();

    run_client("TLS with lws context", sub {
        my $tls_sock = IO::Socket::SSL->new(
            PeerAddr        => "localhost:$tls_port",
            SSL_verify_mode => 0,
            Timeout         => 5,
        ) or return 1;
        $tls_sock->print("GET /tls-test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        my $response = '';
        while (my $line = <$tls_sock>) { $response .= $line }
        $tls_sock->close;
        return 2 unless $response =~ /HTTP\/1\.1 200/;
        return 3 unless $response =~ /tls-ok/;
        return 0;
    });
}

# ---------------------------------------------------------------
# Test 5: Fork with lws context active - does the parent's
# server survive when child inherits lws watchers?
# ---------------------------------------------------------------
{
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        # Child: just exit immediately - the lws context is inherited
        # and its fd watchers may conflict with parent
        _exit(0);
    }

    # Parent: wait for child, then try another TLS request
    waitpid($pid, 0);
    is $? >> 8, 0, "child exited cleanly";

    run_client("TLS after fork with lws context", sub {
        my $tls_sock = IO::Socket::SSL->new(
            PeerAddr        => "localhost:$tls_port",
            SSL_verify_mode => 0,
            Timeout         => 5,
        ) or return 1;
        $tls_sock->print("GET /post-fork HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        my $response = '';
        while (my $line = <$tls_sock>) { $response .= $line }
        $tls_sock->close;
        return ($response =~ /tls-ok/) ? 0 : 2;
    });
}

# Clean up TLS context to avoid accumulated watcher interference
# ($ctx_early, $ctx_late, $ctx3 already cleaned up at line 101-103)
undef $ctx_tls;

# ---------------------------------------------------------------
# Test 6: Eager lws ctx + TLS via run_client (proper AE integration)
# ---------------------------------------------------------------
{
    my ($s6, $p6) = get_listen_socket();
    ok $s6, "test6: got socket on port $p6";

    my $evh6 = Feersum->new_instance();
    $evh6->use_socket($s6);
    eval { $evh6->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
    $evh6->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], \"sim-ok");
    });

    my $ctx6 = EV::Websockets::Context->new(ssl_init => 0);

    SKIP: {
        eval { require IO::Socket::SSL };
        skip "IO::Socket::SSL not available", 2 if $@;
        skip "OpenSSL too old for TLS 1.3", 2 unless tls_client_ok();

        run_client("TLS with eager lws ctx", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr        => "127.0.0.1:$p6",
                SSL_verify_mode => 0,
                Timeout         => 5,
            ) or return 1;
            $sock->print("GET /sim HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            my $resp = '';
            while (my $l = <$sock>) { $resp .= $l }
            $sock->close;
            return ($resp =~ /sim-ok/) ? 0 : 2;
        });
    }
}
