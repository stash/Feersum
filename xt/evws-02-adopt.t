#!perl
# EV::Websockets adopt() integration test (no browser).
# Tests Feersum io() + lws adopt(initial_data) over plain and TLS,
# including keepalive, multi-message, large message, and rapid-fire.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

eval { require EV::Websockets }
    or plan skip_all => "EV::Websockets not installed";
eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";

my $has_tls = Feersum->new_instance()->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
my $has_certs = -f $cert_file && -f $key_file;

plan skip_all => "OpenSSL too old for TLS 1.3" unless tls_client_ok();

plan tests => $has_tls && $has_certs ? 9 : 6;

my $CRLF = "\015\012";

sub ws_read_frame {
    my ($s) = @_;
    my $hdr;
    return undef unless ($s->read($hdr, 2) || 0) == 2;
    my ($b0, $b1) = unpack("CC", $hdr);
    my $len = $b1 & 0x7f;
    if ($len == 126) {
        my $ext; $s->read($ext, 2) or return undef;
        $len = unpack("n", $ext);
    } elsif ($len == 127) {
        my $ext; $s->read($ext, 8) or return undef;
        $len = unpack("Q>", $ext);
    }
    my $payload = '';
    while (length($payload) < $len) {
        $s->read($payload, $len - length($payload), length($payload)) or return undef;
    }
    return $payload;
}

sub ws_send_frame {
    my ($s, $msg) = @_;
    my $len = length($msg);
    if ($len < 126) {
        $s->print(pack("CC", 0x81, $len) . $msg);
    } elsif ($len < 65536) {
        $s->print(pack("CCn", 0x81, 126, $len) . $msg);
    } else {
        $s->print(pack("CCQ>", 0x81, 127, $len) . $msg);
    }
}

sub setup_adopt_handler {
    my ($feer, $ctx, $prefix) = @_;
    $feer->request_handler(sub {
        my $r = shift;
        my $upgrade = $r->header('upgrade') // '';
        unless ($upgrade =~ /websocket/i) {
            my $body = "${prefix}-http-ok";
            $r->send_response(200, [
                'Content-Type' => 'text/plain',
                'Content-Length' => length($body),
            ], \$body);
            return;
        }
        my $raw = $r->method() . " " . $r->uri() . " " . $r->protocol() . $CRLF;
        my $hdrs = $r->headers(0);
        while (my ($k, $v) = each %$hdrs) { $raw .= "$k: $v$CRLF" }
        $raw .= $CRLF;
        my $io = $r->io() or return;
        $ctx->adopt(
            fh           => $io,
            initial_data => $raw,
            on_connect   => sub { $_[0]->send("${prefix}-hello") },
            on_message   => sub {
                my ($c, $data) = @_;
                if ($data =~ /^echo:(.*)$/s) { $c->send("${prefix}-echo:$1") }
                elsif ($data =~ /^close:(\d+):(.*)$/) { $c->close($1, $2) }
            },
            on_close => sub {}, on_error => sub {},
        );
    });
}

# Full WS client: upgrade, multi-message, large, rapid-fire.
sub ws_client {
    my (%opt) = @_;
    my $port   = $opt{port};
    my $tls    = $opt{tls};
    my $prefix = $opt{prefix};

    my $s;
    if ($tls) {
        $s = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 10 * TMULT,
        ) or return 10;
    } else {
        require IO::Socket::INET;
        $s = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10 * TMULT,
        ) or return 10;
    }

    # Optional keepalive HTTP request first
    if ($opt{keepalive}) {
        $s->print("GET /ka HTTP/1.1${CRLF}Host: localhost${CRLF}Connection: keep-alive${CRLF}${CRLF}");
        my $r = '';
        while (1) {
            my $line = $tls ? $s->getline() : <$s>;
            last unless defined $line;
            $r .= $line;
            last if $r =~ /\015\012\015\012/;
        }
        if ($r =~ /Content-Length:\s*(\d+)/i) {
            my $body = '';
            $s->read($body, $1);
            $r .= $body;
        }
        return 20 unless $r =~ /${prefix}-http-ok/;
    }

    # WS upgrade
    $s->print("GET /ws HTTP/1.1${CRLF}Host: localhost${CRLF}"
            . "Upgrade: websocket${CRLF}Connection: Upgrade${CRLF}"
            . "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==${CRLF}"
            . "Sec-WebSocket-Version: 13${CRLF}${CRLF}");

    my $resp = '';
    while (1) {
        my $line = $tls ? $s->getline() : <$s>;
        last unless defined $line;
        $resp .= $line;
        last if $line eq $CRLF;
    }
    return 11 unless $resp =~ /101 Switching/;

    # Welcome
    my $welcome = ws_read_frame($s);
    return 12 unless defined $welcome && $welcome eq "${prefix}-hello";

    # Echo round-trip
    ws_send_frame($s, "echo:test-${prefix}");
    my $echo = ws_read_frame($s);
    return 13 unless defined $echo && $echo eq "${prefix}-echo:test-${prefix}";

    # Multiple round-trips (plain only - TLS tunnel relay is slower)
    unless ($tls) {
        for my $i (1..10) {
            ws_send_frame($s, "echo:msg-$i");
            my $reply = ws_read_frame($s);
            return 16 unless defined $reply && $reply eq "${prefix}-echo:msg-$i";
        }
        # Rapid-fire: send 5 before reading
        for my $i (1..5) { ws_send_frame($s, "echo:rapid-$i") }
        for my $i (1..5) {
            my $reply = ws_read_frame($s);
            return 17 unless defined $reply && $reply eq "${prefix}-echo:rapid-$i";
        }
    }

    # Close
    ws_send_frame($s, "close:4001:done");
    select(undef, undef, undef, 0.2);
    $tls ? $s->close(SSL_no_shutdown => 1) : $s->close();
    return 0;
}

# TLS tests first - lws context accumulation from prior tests can starve TLS accept.

if ($has_tls && $has_certs) {
# =========================================================================
# Test 1: TLS - fresh connection
# =========================================================================
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "tls fresh: listen on $port";
    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    my $ctx = EV::Websockets::Context->new();
    setup_adopt_handler($feer, $ctx, 'tf');
    run_client("tls-fresh", sub { ws_client(port => $port, tls => 1, prefix => 'tf') });
}

} # has_tls

# =========================================================================
# Test 2: plain HTTP - fresh connection
# =========================================================================
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "plain fresh: listen on $port";
    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);
    my $ctx = EV::Websockets::Context->new();
    setup_adopt_handler($feer, $ctx, 'pf');
    run_client("plain-fresh", sub { ws_client(port => $port, tls => 0, prefix => 'pf') });
}

# =========================================================================
# Test 3: plain HTTP - keepalive then WS upgrade
# =========================================================================
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "plain keepalive: listen on $port";
    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);
    $feer->set_keepalive(1);
    my $ctx = EV::Websockets::Context->new();
    setup_adopt_handler($feer, $ctx, 'pk');
    run_client("plain-keepalive", sub { ws_client(port => $port, tls => 0, prefix => 'pk', keepalive => 1) });
}
