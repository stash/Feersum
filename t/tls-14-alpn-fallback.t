#!perl
# Test TLS ALPN negotiation: fallback to HTTP/1.1 when H2 isn't offered
# by the client, and correct protocol selection when both are available.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

plan skip_all => "Feersum not compiled with H2 support"
    unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available"
    if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

my @received;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    push @received, {
        path   => $env->{PATH_INFO} || '/',
        proto  => $env->{SERVER_PROTOCOL} || 'unknown',
    };
    my $body = "proto=" . ($env->{SERVER_PROTOCOL} || 'unknown');
    $r->send_response(200, [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($body),
        'Connection'     => 'close',
    ], $body);
});

# ========================================================================
# Test 1: Client offers only http/1.1 ALPN -> should get HTTP/1.1
# ========================================================================
{
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

        my $client = IO::Socket::SSL->new(
            PeerAddr           => '127.0.0.1',
            PeerPort           => $port,
            SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
            SSL_alpn_protocols => ['http/1.1'],
            Timeout            => 5 * TIMEOUT_MULT,
        );
        unless ($client) {
            warn "TLS connect (http/1.1 ALPN) failed: " . IO::Socket::SSL::errstr() . "\n";
            exit(1);
        }

        # An http/1.1-only client must never be steered to h2 by ALPN.
        my $proto = $client->alpn_selected() || '';
        if ($proto eq 'h2') {
            warn "ALPN wrongly negotiated h2 for an http/1.1-only client\n";
            exit(3);
        }

        $client->print(
            "GET /alpn-h11 HTTP/1.1\r\n" .
            "Host: localhost:$port\r\n" .
            "Connection: close\r\n" .
            "\r\n"
        );

        my $response = '';
        while (defined(my $line = $client->getline())) {
            $response .= $line;
        }
        $client->close(SSL_no_shutdown => 1);

        exit($response =~ /200 OK/ ? 0 : 2);
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(10 * TIMEOUT_MULT, 0, sub {
        diag "timeout";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "http/1.1 ALPN: did not timeout";
    is $child_status, 0, "http/1.1 ALPN: got 200 OK via HTTP/1.1";

    if (@received) {
        like $received[-1]{proto}, qr/HTTP\/1\.[01]/, "http/1.1 ALPN: protocol is HTTP/1.x";
    }
}

# ========================================================================
# Test 2: Client offers NO ALPN -> should fall back to HTTP/1.1
# ========================================================================
{
    @received = ();
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

        # Connect without ALPN at all
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 5 * TIMEOUT_MULT,
            # No SSL_alpn_protocols - deliberately omitted
        );
        unless ($client) {
            warn "TLS connect (no ALPN) failed: " . IO::Socket::SSL::errstr() . "\n";
            exit(1);
        }

        $client->print(
            "GET /no-alpn HTTP/1.1\r\n" .
            "Host: localhost:$port\r\n" .
            "Connection: close\r\n" .
            "\r\n"
        );

        my $response = '';
        while (defined(my $line = $client->getline())) {
            $response .= $line;
        }
        $client->close(SSL_no_shutdown => 1);

        exit($response =~ /200 OK/ ? 0 : 2);
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(10 * TIMEOUT_MULT, 0, sub {
        diag "timeout";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "no ALPN: did not timeout";
    is $child_status, 0, "no ALPN: got 200 OK via HTTP/1.1 fallback";

    if (@received) {
        like $received[-1]{proto}, qr/HTTP\/1\.[01]/, "no ALPN: protocol is HTTP/1.x";
    }
}

# ========================================================================
# Test 3: Client offers h2 ALPN -> should get HTTP/2
# (Baseline verification that H2 actually works on this listener)
# ========================================================================
{
    my $nghttp_bin = `which nghttp 2>/dev/null` || '';
    chomp $nghttp_bin;

    SKIP: {
        skip "nghttp not found in PATH", 3 unless $nghttp_bin && -x $nghttp_bin;

        @received = ();
        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0) {
            select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
            my $output = `$nghttp_bin --no-verify https://127.0.0.1:$port/h2-alpn 2>&1`;
            my $rc = $? >> 8;
            exit($rc == 0 && $output =~ /proto=HTTP\/2/ ? 0 : 2);
        }

        my $cv = AE::cv;
        my $child_status;
        my $t = AE::timer(10 * TIMEOUT_MULT, 0, sub {
            diag "timeout";
            $cv->send('timeout');
        });
        my $cw = AE::child($pid, sub {
            $child_status = $_[1] >> 8;
            $cv->send('child_done');
        });

        my $reason = $cv->recv;
        isnt $reason, 'timeout', "h2 ALPN: did not timeout";
        is $child_status, 0, "h2 ALPN: nghttp got HTTP/2 response";

        if (@received) {
            is $received[-1]{proto}, 'HTTP/2', "h2 ALPN: protocol is HTTP/2";
        }
    }
}

done_testing;
