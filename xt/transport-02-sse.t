#!perl
# Extended test: SSE streaming across plain, TLS/H1, H2, with proxy v1/v2
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || 1;
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;

use Feersum;

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

my $HAS_TLS = Feersum->new()->has_tls();
my $HAS_H2  = Feersum->new()->has_h2();
my $HAS_SSL = eval { require IO::Socket::SSL; 1 };
my $HAS_CERTS = -f $cert_file && -f $key_file;

use H2Utils;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Count "data:" lines in SSE stream
sub count_sse_events {
    my ($text) = @_;
    my @events = ($text =~ /^data: /mg);
    return scalar @events;
}

# ===========================================================================
# SSE handler: sends 3 events with addr info, then closes
# ===========================================================================
my $sse_handler = sub {
    my $req = shift;
    my $env = $req->env();
    my $addr = $env->{REMOTE_ADDR} || 'unknown';

    my $w = $req->start_streaming(200, [
        'Content-Type'  => 'text/event-stream',
        'Cache-Control' => 'no-cache',
    ]);

    my $n = 0;
    my $t; $t = AE::timer(0.05, 0.05, sub {
        $n++;
        eval { $w->write("data: event-$n addr=$addr\n\n") };
        if ($n >= 3) {
            undef $t;
            eval { $w->close() };
        }
    });
};

# ===========================================================================
# Test 1: Plain SSE
# ===========================================================================
subtest 'Plain SSE streaming' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "plain-sse: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($sse_handler);

    run_client("plain SSE", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        my $buf = '';
        my $deadline = time + 10 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            last if count_sse_events($buf) >= 3;
        }
        $sock->close;
        return count_sse_events($buf) >= 3 ? 0 : 2;
    });
};

# ===========================================================================
# Test 2: TLS SSE
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS SSE streaming' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "tls-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($sse_handler);

        run_client("tls SSE", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

            my $buf = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $buf .= $chunk;
                last if count_sse_events($buf) >= 3;
            }
            $sock->close(SSL_no_shutdown => 1);
            return count_sse_events($buf) >= 3 ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 3: H2 SSE
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 SSE streaming' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "h2-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($sse_handler);

        run_client("h2 SSE", sub {
            my $sock = h2_connect($port) or return 1;

            # Send GET request for SSE
            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'],
                [':path', '/events'],
                [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            my $got_200 = 0;
            my $data = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                }
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $data .= $f->{payload};
                    if (length($f->{payload}) > 0) {
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                    }
                    last if $f->{flags} & FLAG_END_STREAM;
                }
                last if count_sse_events($data) >= 3;
            }
            $sock->close;
            return ($got_200 && count_sse_events($data) >= 3) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 4: Proxy v1 + TLS SSE
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v1 + TLS SSE' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v1-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($sse_handler);

        run_client("proxy-v1 TLS SSE", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '192.168.1.1', '192.168.1.2', 22222, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            $raw->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

            my $buf = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $raw->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $buf .= $chunk;
                last if count_sse_events($buf) >= 3;
            }
            $raw->close(SSL_no_shutdown => 1);
            my $events = count_sse_events($buf);
            return ($events >= 3 && $buf =~ /addr=192\.168\.1\.1/) ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 5: Proxy v2 + TLS SSE
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 + TLS SSE' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($sse_handler);

        run_client("proxy-v2 TLS SSE", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '10.20.30.40', '10.20.30.41', 33333, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            $raw->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

            my $buf = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $raw->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $buf .= $chunk;
                last if count_sse_events($buf) >= 3;
            }
            $raw->close(SSL_no_shutdown => 1);
            my $events = count_sse_events($buf);
            return ($events >= 3 && $buf =~ /addr=10\.20\.30\.40/) ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 6: Proxy v1 + H2 SSE
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v1 + H2 SSE' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v1-h2-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($sse_handler);

        run_client("proxy-v1 H2 SSE", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '172.20.0.1', '172.20.0.2', 44444, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            h2_handshake($raw);

            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/events'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $raw->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            my $data = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $data .= $f->{payload};
                    if (length($f->{payload}) > 0) {
                        $raw->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $raw->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                    }
                    last if $f->{flags} & FLAG_END_STREAM;
                }
                last if count_sse_events($data) >= 3;
            }
            $raw->close;
            return (count_sse_events($data) >= 3 && $data =~ /addr=172\.20\.0\.1/) ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 7: Proxy v2 + H2 SSE
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 + H2 SSE' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-h2-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($sse_handler);

        run_client("proxy-v2 H2 SSE", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '203.0.113.99', '203.0.113.100', 55555, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            h2_handshake($raw);

            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/events'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $raw->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            my $data = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $data .= $f->{payload};
                    if (length($f->{payload}) > 0) {
                        $raw->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $raw->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                    }
                    last if $f->{flags} & FLAG_END_STREAM;
                }
                last if count_sse_events($data) >= 3;
            }
            $raw->close;
            return (count_sse_events($data) >= 3 && $data =~ /addr=203\.0\.113\.99/) ? 0 : 3;
        });
    };
}

# ===========================================================================
# SSE handler for disconnect tests: sends many events slowly
# ===========================================================================
my $sse_disconnect_handler = sub {
    my $req = shift;
    my $w = $req->start_streaming(200, [
        'Content-Type'  => 'text/event-stream',
        'Cache-Control' => 'no-cache',
    ]);
    my $n = 0;
    my $t; $t = AE::timer(0.02, 0.05, sub {
        $n++;
        eval { $w->write("data: event-$n\n\n") };
        if ($@) { undef $t; return; }
        if ($n >= 30) { undef $t; eval { $w->close() }; }
    });
};

# ===========================================================================
# Test 8: Plain SSE client disconnect
# ===========================================================================
subtest 'Plain SSE: client disconnect' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "disconnect-plain-sse: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($sse_disconnect_handler);

    run_client("plain SSE disconnect", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        my $buf = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            last if count_sse_events($buf) >= 1;
        }
        close($sock);  # abrupt disconnect
        return (count_sse_events($buf) >= 1) ? 0 : 2;
    });
};

# ===========================================================================
# Test 9: TLS SSE client disconnect
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS SSE: client disconnect' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-tls-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($sse_disconnect_handler);

        run_client("tls SSE disconnect", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            my $buf = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $buf .= $chunk;
                last if count_sse_events($buf) >= 1;
            }
            close($sock);  # abrupt disconnect, no SSL shutdown
            return (count_sse_events($buf) >= 1) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 10: H2 SSE client disconnect (RST_STREAM)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 SSE: client disconnect (RST_STREAM)' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-h2-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($sse_disconnect_handler);

        run_client("h2 SSE disconnect", sub {
            my $sock = h2_connect($port) or return 1;

            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/events'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            # Wait for at least 1 DATA frame
            my $got_data = 0;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1 && length($f->{payload}) > 0) {
                    $got_data = 1;
                    last;
                }
            }

            # Send RST_STREAM (CANCEL=0x08) to abort
            $sock->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 0x08)));
            select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
            $sock->close;
            return $got_data ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 11: Proxy v1 + plain SSE
# ===========================================================================
subtest 'Proxy v1+plain SSE' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "proxy-v1-plain-sse: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->use_socket($socket);
    $evh->request_handler($sse_handler);

    run_client("proxy-v1 plain SSE", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->syswrite(build_proxy_v1('TCP4', '10.0.0.1', '10.0.0.2', 12345, 80));
        $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        my $buf = '';
        my $deadline = time + 10 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            last if count_sse_events($buf) >= 3;
        }
        $sock->close;
        return (count_sse_events($buf) >= 3 && $buf =~ /addr=10\.0\.0\.1/) ? 0 : 2;
    });
};

# ===========================================================================
# Test 12: Proxy v2 + plain SSE
# ===========================================================================
subtest 'Proxy v2+plain SSE' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "proxy-v2-plain-sse: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->use_socket($socket);
    $evh->request_handler($sse_handler);

    run_client("proxy-v2 plain SSE", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->syswrite(build_proxy_v2('PROXY', 'INET', '192.168.1.1', '192.168.1.2', 54321, 80));
        $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        my $buf = '';
        my $deadline = time + 10 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            last if count_sse_events($buf) >= 3;
        }
        $sock->close;
        return (count_sse_events($buf) >= 3 && $buf =~ /addr=192\.168\.1\.1/) ? 0 : 2;
    });
};

# ===========================================================================
# PSGI SSE handler - delayed response with writer
# ===========================================================================
my $psgi_sse_handler = sub {
    my $env = shift;
    my $addr = $env->{REMOTE_ADDR} || 'unknown';

    return sub {
        my $responder = shift;
        my $w = $responder->([200, [
            'Content-Type'  => 'text/event-stream',
            'Cache-Control' => 'no-cache',
        ]]);

        my $n = 0;
        my $t; $t = AE::timer(0.05, 0.05, sub {
            $n++;
            eval { $w->write("data: event-$n addr=$addr\n\n") };
            if ($n >= 3) {
                undef $t;
                eval { $w->close() };
            }
        });
    };
};

# ===========================================================================
# Test 13: PSGI SSE (plain)
# ===========================================================================
subtest 'PSGI: Plain SSE streaming' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "psgi-plain-sse: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->psgi_request_handler($psgi_sse_handler);

    run_client("psgi plain SSE", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        my $buf = '';
        my $deadline = time + 10 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            last if count_sse_events($buf) >= 3;
        }
        $sock->close;
        return count_sse_events($buf) >= 3 ? 0 : 2;
    });
};

# ===========================================================================
# Test 14: PSGI SSE (TLS)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI: TLS SSE streaming' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-tls-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->psgi_request_handler($psgi_sse_handler);

        run_client("psgi tls SSE", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $sock->print("GET /events HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

            my $buf = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $buf .= $chunk;
                last if count_sse_events($buf) >= 3;
            }
            $sock->close(SSL_no_shutdown => 1);
            return count_sse_events($buf) >= 3 ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 15: PSGI SSE (H2)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI: H2 SSE streaming' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-h2-sse: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->psgi_request_handler($psgi_sse_handler);

        run_client("psgi h2 SSE", sub {
            my $sock = h2_connect($port) or return 1;

            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'],
                [':path', '/events'],
                [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            my $got_200 = 0;
            my $data = '';
            my $deadline = time + 10 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                }
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $data .= $f->{payload};
                    if (length($f->{payload}) > 0) {
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                    }
                    last if $f->{flags} & FLAG_END_STREAM;
                }
                last if count_sse_events($data) >= 3;
            }
            $sock->close;
            return ($got_200 && count_sse_events($data) >= 3) ? 0 : 2;
        });
    };
}

done_testing;
