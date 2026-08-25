#!perl
# Extended test: Bidirectional IO across plain, TLS/H1, H2, with proxy v1/v2
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || 1;
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;

use Feersum;

my $CRLF = "\015\012";
my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

my $HAS_TLS = Feersum->new()->has_tls();
my $HAS_H2  = Feersum->new()->has_h2();
my $HAS_SSL = eval { require IO::Socket::SSL; 1 };
my $HAS_CERTS = -f $cert_file && -f $key_file;

use H2Utils;

# ===========================================================================
# IO handler: upgrade via io(), echo lines with an "echo:" prefix.  One code
# path for H1 (raw socket) and H2 (socketpair behind an automatic 200); the
# 101 written below goes out on H1 and is swallowed on H2.
# ===========================================================================
my @io_captured;
my $io_handler = sub {
    my $req = shift;
    my $env = $req->env();
    my $addr = $env->{REMOTE_ADDR} || 'unknown';

    push @io_captured, { addr => $addr };

    my $io = $req->io();
    unless ($io) {
        $req->send_response(500, ['Content-Type' => 'text/plain'], \"io() failed\n");
        return;
    }
    syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

    # Echo handler using AnyEvent::Handle
    my $h; $h = AnyEvent::Handle->new(
        fh       => $io,
        on_error => sub { $_[0]->destroy; undef $h; },
        on_eof   => sub { $h->destroy if $h; undef $h; },
    );
    $h->on_read(sub {
        my $data = $h->{rbuf};
        $h->{rbuf} = '';
        $h->push_write("echo:$data");
    });
};

# ===========================================================================
# Test 1: Plain IO upgrade + echo
# ===========================================================================
subtest 'Plain IO upgrade + echo' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "plain-io: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($io_handler);

    @io_captured = ();
    run_client("plain IO", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;

        # Send upgrade request
        $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        # Read 101 response
        my $response = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $response .= $buf;
            last if $response =~ /\r\n\r\n/;
        }
        return 2 unless $response =~ /101 Switching/;

        # Send data, read echo
        $sock->print("hello\n");
        my $echo = '';
        $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $echo .= $buf;
            last if $echo =~ /\n/;
        }
        $sock->close;
        return ($echo eq "echo:hello\n") ? 0 : 3;
    });
};

# ===========================================================================
# Test 2: TLS IO upgrade + echo (socketpair tunnel)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS IO upgrade + echo' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "tls-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($io_handler);

        @io_captured = ();
        run_client("tls IO", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;

            $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

            my $response = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            return 2 unless $response =~ /101 Switching/;

            $sock->print("hello-tls\n");
            my $echo = '';
            $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $echo .= $buf;
                last if $echo =~ /\n/;
            }
            $sock->close(SSL_no_shutdown => 1);
            return ($echo eq "echo:hello-tls\n") ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 3: H2 Extended CONNECT IO + echo
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 Extended CONNECT IO + echo' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "h2-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($io_handler);

        @io_captured = ();
        run_client("h2 IO", sub {
            my $sock = h2_connect($port) or return 1;

            # Send Extended CONNECT with initial data
            my $hdr_block = hpack_encode_headers(
                [':method', 'CONNECT'],
                [':protocol', 'websocket'],
                [':path', '/tunnel'],
                [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block);
            $out .= h2_frame(H2_DATA, 0, 1, "hello-h2\n");
            $sock->syswrite($out);

            # Read 200 HEADERS
            my $got_200 = 0;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                    last;
                }
            }
            return 2 unless $got_200;

            # Read echoed data
            my $echo = '';
            $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $echo .= $f->{payload};
                    last if $echo =~ /\n/;
                }
            }

            # Close stream
            $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
            select(undef, undef, undef, 0.2);
            $sock->close;
            return ($echo eq "echo:hello-h2\n") ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 4: Proxy v1 + TLS IO
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v1 + TLS IO' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v1-tls-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($io_handler);

        @io_captured = ();
        run_client("proxy-v1 TLS IO", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '10.10.10.1', '10.10.10.2', 11111, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;

            $raw->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

            my $response = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $raw->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            return 3 unless $response =~ /101 Switching/;

            $raw->print("proxy-echo\n");
            my $echo = '';
            $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $raw->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $echo .= $buf;
                last if $echo =~ /\n/;
            }
            $raw->close(SSL_no_shutdown => 1);
            return ($echo eq "echo:proxy-echo\n") ? 0 : 4;
        });

        cmp_ok scalar(@io_captured), '>=', 1, "proxy-v1-tls-io: handler was called";
        is $io_captured[0]{addr}, '10.10.10.1', "proxy-v1-tls-io: REMOTE_ADDR from proxy";
    };
}

# ===========================================================================
# Test 5: Proxy v2 + TLS IO
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 + TLS IO' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-tls-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($io_handler);

        @io_captured = ();
        run_client("proxy-v2 TLS IO", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '198.51.100.50', '198.51.100.51', 22222, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;

            $raw->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

            my $response = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $raw->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            return 3 unless $response =~ /101 Switching/;

            $raw->print("v2-echo\n");
            my $echo = '';
            $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $raw->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $echo .= $buf;
                last if $echo =~ /\n/;
            }
            $raw->close(SSL_no_shutdown => 1);
            return ($echo eq "echo:v2-echo\n") ? 0 : 4;
        });

        cmp_ok scalar(@io_captured), '>=', 1, "proxy-v2-tls-io: handler was called";
        is $io_captured[0]{addr}, '198.51.100.50', "proxy-v2-tls-io: REMOTE_ADDR from proxy";
    };
}

# ===========================================================================
# Test 6: Proxy v1 + H2 IO
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v1 + H2 IO' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v1-h2-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($io_handler);

        @io_captured = ();
        run_client("proxy-v1 H2 IO", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '172.30.0.1', '172.30.0.2', 33333, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            h2_handshake($raw);

            # Extended CONNECT + initial data
            my $hdr_block = hpack_encode_headers(
                [':method', 'CONNECT'], [':protocol', 'websocket'],
                [':path', '/tunnel'], [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block);
            $out .= h2_frame(H2_DATA, 0, 1, "proxy-h2-echo\n");
            $raw->syswrite($out);

            # Read 200
            my $got_200 = 0;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                    last;
                }
            }
            return 3 unless $got_200;

            # Read echo
            my $echo = '';
            $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $echo .= $f->{payload};
                    last if $echo =~ /\n/;
                }
            }

            $raw->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
            select(undef, undef, undef, 0.2);
            $raw->close;
            return ($echo eq "echo:proxy-h2-echo\n") ? 0 : 4;
        });

        cmp_ok scalar(@io_captured), '>=', 1, "proxy-v1-h2-io: handler was called";
        is $io_captured[0]{addr}, '172.30.0.1', "proxy-v1-h2-io: REMOTE_ADDR from proxy";
    };
}

# ===========================================================================
# Test 7: Proxy v2 + H2 IO
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 + H2 IO' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-h2-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($io_handler);

        @io_captured = ();
        run_client("proxy-v2 H2 IO", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '203.0.113.77', '203.0.113.78', 44444, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            h2_handshake($raw);

            my $hdr_block = hpack_encode_headers(
                [':method', 'CONNECT'], [':protocol', 'websocket'],
                [':path', '/tunnel'], [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block);
            $out .= h2_frame(H2_DATA, 0, 1, "v2-h2-echo\n");
            $raw->syswrite($out);

            my $got_200 = 0;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                    last;
                }
            }
            return 3 unless $got_200;

            my $echo = '';
            $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $echo .= $f->{payload};
                    last if $echo =~ /\n/;
                }
            }

            $raw->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
            select(undef, undef, undef, 0.2);
            $raw->close;
            return ($echo eq "echo:v2-h2-echo\n") ? 0 : 4;
        });

        cmp_ok scalar(@io_captured), '>=', 1, "proxy-v2-h2-io: handler was called";
        is $io_captured[0]{addr}, '203.0.113.77', "proxy-v2-h2-io: REMOTE_ADDR from proxy";
    };
}

# ===========================================================================
# Test 8: Plain IO client disconnect
# ===========================================================================
subtest 'Plain IO: client disconnect' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "disconnect-plain-io: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($io_handler);

    run_client("plain IO disconnect", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;

        $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        my $response = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $response .= $buf;
            last if $response =~ /\r\n\r\n/;
        }
        return 2 unless $response =~ /101 Switching/;

        # Send one message, get echo, then disconnect abruptly
        $sock->print("hello\n");
        my $echo = '';
        $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $echo .= $buf;
            last if $echo =~ /\n/;
        }
        close($sock);  # abrupt disconnect
        return ($echo eq "echo:hello\n") ? 0 : 3;
    });
};

# ===========================================================================
# Test 9: TLS IO client disconnect
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS IO: client disconnect' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-tls-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($io_handler);

        run_client("tls IO disconnect", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;

            $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

            my $response = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            return 2 unless $response =~ /101 Switching/;

            $sock->print("hello-tls\n");
            my $echo = '';
            $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $echo .= $buf;
                last if $echo =~ /\n/;
            }
            close($sock);  # abrupt disconnect, no SSL shutdown
            return ($echo eq "echo:hello-tls\n") ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 10: H2 IO client disconnect (RST_STREAM)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 IO: client disconnect (RST_STREAM)' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-h2-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($io_handler);

        run_client("h2 IO disconnect", sub {
            my $sock = h2_connect($port) or return 1;

            # Extended CONNECT + initial data
            my $hdr_block = hpack_encode_headers(
                [':method', 'CONNECT'], [':protocol', 'websocket'],
                [':path', '/tunnel'], [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block);
            $out .= h2_frame(H2_DATA, 0, 1, "hello-h2\n");
            $sock->syswrite($out);

            # Read 200 HEADERS
            my $got_200 = 0;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                    last;
                }
            }
            return 2 unless $got_200;

            # Read echo
            my $echo = '';
            $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $echo .= $f->{payload};
                    last if $echo =~ /\n/;
                }
            }

            # RST_STREAM (CANCEL) to abort the tunnel
            $sock->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 0x08)));
            select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
            $sock->close;
            return ($echo eq "echo:hello-h2\n") ? 0 : 3;
        });
    };
}

# ===========================================================================
# Test 11: Proxy v1 + plain IO
# ===========================================================================
subtest 'Proxy v1+plain IO' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "proxy-v1-plain-io: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->use_socket($socket);
    $evh->request_handler($io_handler);

    @io_captured = ();
    run_client("proxy-v1 plain IO", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->syswrite(build_proxy_v1('TCP4', '10.20.30.1', '10.20.30.2', 12345, 80));
        $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        my $response = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $response .= $buf;
            last if $response =~ /\r\n\r\n/;
        }
        return 2 unless $response =~ /101 Switching/;

        $sock->print("proxy-plain-echo\n");
        my $echo = '';
        $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $echo .= $buf;
            last if $echo =~ /\n/;
        }
        $sock->close;
        return ($echo eq "echo:proxy-plain-echo\n") ? 0 : 3;
    });

    cmp_ok scalar(@io_captured), '>=', 1, "proxy-v1-plain-io: handler was called";
    is $io_captured[0]{addr}, '10.20.30.1', "proxy-v1-plain-io: REMOTE_ADDR from proxy";
};

# ===========================================================================
# Test 12: Proxy v2 + plain IO
# ===========================================================================
subtest 'Proxy v2+plain IO' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "proxy-v2-plain-io: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->use_socket($socket);
    $evh->request_handler($io_handler);

    @io_captured = ();
    run_client("proxy-v2 plain IO", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->syswrite(build_proxy_v2('PROXY', 'INET', '192.168.50.1', '192.168.50.2', 54321, 80));
        $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        my $response = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $response .= $buf;
            last if $response =~ /\r\n\r\n/;
        }
        return 2 unless $response =~ /101 Switching/;

        $sock->print("proxy-v2-echo\n");
        my $echo = '';
        $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $echo .= $buf;
            last if $echo =~ /\n/;
        }
        $sock->close;
        return ($echo eq "echo:proxy-v2-echo\n") ? 0 : 3;
    });

    cmp_ok scalar(@io_captured), '>=', 1, "proxy-v2-plain-io: handler was called";
    is $io_captured[0]{addr}, '192.168.50.1', "proxy-v2-plain-io: REMOTE_ADDR from proxy";
};

# ===========================================================================
# PSGI IO handler - uses psgix.io for protocol upgrade
# ===========================================================================
my @psgi_io_captured;
my $psgi_io_handler = sub {
    my $env = shift;
    my $addr = $env->{REMOTE_ADDR} || 'unknown';

    push @psgi_io_captured, { addr => $addr };

    return sub {
        my $responder = shift;

        # Same code for H1 and H2 - psgix.io magic handles the difference:
        # H1: returns raw socket; H2: auto-sends 200 HEADERS, returns socketpair
        # The 101 response written below is sent on H1, swallowed on H2.
        my $io = $env->{'psgix.io'};
        unless ($io) {
            $responder->([500, ['Content-Type' => 'text/plain'], ['psgix.io unavailable']]);
            return;
        }
        syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        my $h; $h = AnyEvent::Handle->new(
            fh       => $io,
            on_error => sub { $_[0]->destroy; undef $h; },
            on_eof   => sub { $h->destroy if $h; undef $h; },
        );
        $h->on_read(sub {
            my $data = $h->{rbuf};
            $h->{rbuf} = '';
            $h->push_write("echo:$data");
        });
    };
};

# ===========================================================================
# Test 13: PSGI IO upgrade + echo (plain)
# ===========================================================================
subtest 'PSGI: Plain IO upgrade + echo' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "psgi-plain-io: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->psgi_request_handler($psgi_io_handler);

    @psgi_io_captured = ();
    run_client("psgi plain IO", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;

        $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        my $response = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $response .= $buf;
            last if $response =~ /\r\n\r\n/;
        }
        return 2 unless $response =~ /101 Switching/;

        $sock->print("hello-psgi\n");
        my $echo = '';
        $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $buf, 4096);
            last if !defined($n) || $n == 0;
            $echo .= $buf;
            last if $echo =~ /\n/;
        }
        $sock->close;
        return ($echo eq "echo:hello-psgi\n") ? 0 : 3;
    });

    cmp_ok scalar(@psgi_io_captured), '>=', 1, "psgi-plain-io: handler was called";
    like $psgi_io_captured[0]{addr}, qr/127\.0\.0\.1/, "psgi-plain-io: REMOTE_ADDR is local";
};

# ===========================================================================
# Test 14: PSGI IO upgrade + echo (TLS)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI: TLS IO upgrade + echo' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-tls-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->psgi_request_handler($psgi_io_handler);

        @psgi_io_captured = ();
        run_client("psgi tls IO", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;

            $sock->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}Upgrade: echo${CRLF}Connection: Upgrade${CRLF}${CRLF}");

            my $response = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $response .= $buf;
                last if $response =~ /\r\n\r\n/;
            }
            return 2 unless $response =~ /101 Switching/;

            $sock->print("hello-psgi-tls\n");
            my $echo = '';
            $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $buf, 4096);
                last if !defined($n) || $n == 0;
                $echo .= $buf;
                last if $echo =~ /\n/;
            }
            $sock->close(SSL_no_shutdown => 1);
            return ($echo eq "echo:hello-psgi-tls\n") ? 0 : 3;
        });

        cmp_ok scalar(@psgi_io_captured), '>=', 1, "psgi-tls-io: handler was called";
        like $psgi_io_captured[0]{addr}, qr/127\.0\.0\.1/, "psgi-tls-io: REMOTE_ADDR is local";
    };
}

# ===========================================================================
# Test 15: PSGI IO upgrade + echo (H2 Extended CONNECT via psgix.io)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI: H2 IO upgrade + echo' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-h2-io: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->psgi_request_handler($psgi_io_handler);

        @psgi_io_captured = ();
        run_client("psgi h2 IO", sub {
            my $sock = h2_connect($port) or return 1;

            # Send Extended CONNECT with initial data
            my $hdr_block = hpack_encode_headers(
                [':method', 'CONNECT'],
                [':protocol', 'websocket'],
                [':path', '/tunnel'],
                [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
            );
            my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block);
            $out .= h2_frame(H2_DATA, 0, 1, "hello-psgi-h2\n");
            $sock->syswrite($out);

            # Read 200 HEADERS
            my $got_200 = 0;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    my $status = hpack_decode_status($f->{payload});
                    $got_200 = 1 if defined $status && $status eq '200';
                    last;
                }
            }
            return 2 unless $got_200;

            # Read echoed data
            my $echo = '';
            $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $echo .= $f->{payload};
                    last if $echo =~ /\n/;
                }
            }

            # Close stream
            $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
            select(undef, undef, undef, 0.2);
            $sock->close;
            return ($echo eq "echo:hello-psgi-h2\n") ? 0 : 3;
        });

        cmp_ok scalar(@psgi_io_captured), '>=', 1, "psgi-h2-io: handler was called";
        like $psgi_io_captured[0]{addr}, qr/127\.0\.0\.1/, "psgi-h2-io: REMOTE_ADDR is local";
    };
}

done_testing;
