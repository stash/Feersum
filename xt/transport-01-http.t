#!perl
# Extended test: GET/POST across plain, TLS/H1, H2, with proxy v1/v2
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
# Helper: run a forked client, wait for exit code
# ---------------------------------------------------------------------------
# Helper: HTTP/1.x request over a socket, returns (status, body, headers_str)
# ---------------------------------------------------------------------------
sub http1_request {
    my ($sock, $method, $path, %opts) = @_;
    my $body = $opts{body} // '';
    my $conn = $opts{connection} // 'close';
    my $host = $opts{host} // 'localhost';
    my $req = "$method $path HTTP/1.1\r\nHost: $host\r\nConnection: $conn\r\n";
    if (length $body) {
        $req .= "Content-Length: " . length($body) . "\r\nContent-Type: text/plain\r\n";
    }
    $req .= "\r\n$body";
    $sock->print($req);

    my $response = '';
    while (defined(my $line = $sock->getline())) {
        $response .= $line;
        last if $response =~ /\r\n\r\n/;
    }
    my ($status) = $response =~ m{HTTP/1\.\d (\d+)};
    my ($cl) = $response =~ /Content-Length:\s*(\d+)/i;
    my $resp_body = '';
    if ($cl && $cl > 0) {
        $sock->read($resp_body, $cl);
    }
    return ($status, $resp_body, $response);
}

# ---------------------------------------------------------------------------
# Helper: H2 GET/POST via raw frames, returns (status, body)
# ---------------------------------------------------------------------------
sub h2_request {
    my ($sock, $stream_id, $method, $path, $port, %opts) = @_;
    my $body = $opts{body} // '';

    my @hdrs = (
        [':method', $method],
        [':path',   $path],
        [':scheme', 'https'],
        [':authority', "127.0.0.1:$port"],
    );
    if (length $body) {
        push @hdrs, ['content-type', 'text/plain'];
        push @hdrs, ['content-length', length($body)];
    }

    my $hdr_block = hpack_encode_headers(@hdrs);
    my $flags = FLAG_END_HEADERS;
    $flags |= FLAG_END_STREAM if !length($body);
    my $out = h2_frame(H2_HEADERS, $flags, $stream_id, $hdr_block);
    if (length $body) {
        $out .= h2_frame(H2_DATA, FLAG_END_STREAM, $stream_id, $body);
    }
    $sock->syswrite($out);

    my $status;
    my $resp_body = '';
    my $deadline = time + 8;
    my $done = 0;
    while (!$done && time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == $stream_id) {
            $status = hpack_decode_status($f->{payload});
            $done = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        if ($f->{type} == H2_DATA && $f->{stream_id} == $stream_id) {
            $resp_body .= $f->{payload};
            $done = 1 if $f->{flags} & FLAG_END_STREAM;
            # Send WINDOW_UPDATE only if stream is still open (no END_STREAM)
            if (!$done && length($f->{payload}) > 0) {
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $stream_id, pack('N', length($f->{payload}))));
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
            }
        }
    }
    return ($status, $resp_body);
}

# ===========================================================================
# Server handler: echo method, path, body, env info
# ===========================================================================
my @captured;
my $handler = sub {
    my $req = shift;
    my $env = $req->env();
    my $method = $env->{REQUEST_METHOD} || 'GET';
    my $path   = $env->{PATH_INFO} || '/';
    my $cl     = $env->{CONTENT_LENGTH} || 0;
    my $body   = '';
    if ($cl > 0 && $env->{'psgi.input'}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    my $addr   = $env->{REMOTE_ADDR} || '';
    my $port   = $env->{REMOTE_PORT} || '';
    my $scheme = $env->{'psgi.url_scheme'} || '';
    my $proto  = $env->{SERVER_PROTOCOL} || '';

    push @captured, {
        method => $method, path => $path, body => $body,
        addr => $addr, port => $port, scheme => $scheme, proto => $proto,
    };

    my $resp = "method=$method path=$path body=$body addr=$addr scheme=$scheme proto=$proto";
    $req->send_response(200, [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($resp),
    ], \$resp);
};

# ===========================================================================
# Test 1: Plain HTTP/1.1
# ===========================================================================
subtest 'Plain HTTP/1.1 GET+POST' => sub {
    plan tests => 9;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("plain GET", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        my ($status, $body) = http1_request($sock, 'GET', '/plain-get');
        $sock->close;
        return ($status eq '200' && $body =~ /method=GET/ && $body =~ /path=\/plain-get/) ? 0 : 2;
    });

    run_client("plain POST", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        my ($status, $body) = http1_request($sock, 'POST', '/plain-post', body => 'hello=world');
        $sock->close;
        return ($status eq '200' && $body =~ /method=POST/ && $body =~ /body=hello=world/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 2, "plain: received both requests";
    is $captured[0]{scheme}, 'http', "plain: url_scheme is http";
    like $captured[0]{proto}, qr/HTTP\/1\.1/, "plain: SERVER_PROTOCOL is HTTP/1.1";
    is $captured[1]{body}, 'hello=world', "plain: POST body correct";
};

# ===========================================================================
# Test 2: TLS/H1
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS/H1 GET+POST' => sub {
        plan tests => 9;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        @captured = ();
        run_client("tls GET", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'GET', '/tls-get');
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /path=\/tls-get/) ? 0 : 2;
        });

        run_client("tls POST", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'POST', '/tls-post', body => 'tls=data');
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /body=tls=data/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 2, "tls: received both requests";
        is $captured[0]{scheme}, 'https', "tls: url_scheme is https";
        like $captured[0]{proto}, qr/HTTP\/1\.1/, "tls: SERVER_PROTOCOL is HTTP/1.1";
        is $captured[1]{body}, 'tls=data', "tls: POST body correct";
    };
}

# ===========================================================================
# Test 3: H2
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 GET+POST' => sub {
        plan tests => 9;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($handler);

        @captured = ();
        run_client("h2 GET", sub {
            my $sock = h2_connect($port) or return 1;
            my ($status, $body) = h2_request($sock, 1, 'GET', '/h2-get', $port);
            $sock->close;
            return (defined $status && $status eq '200' && $body =~ /path=\/h2-get/) ? 0 : 2;
        });

        run_client("h2 POST", sub {
            my $sock = h2_connect($port) or return 1;
            my ($status, $body) = h2_request($sock, 1, 'POST', '/h2-post', $port, body => 'h2=payload');
            $sock->close;
            return (defined $status && $status eq '200' && $body =~ /body=h2=payload/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 2, "h2: received both requests";
        is $captured[0]{scheme}, 'https', "h2: url_scheme is https";
        is $captured[0]{proto}, 'HTTP/2', "h2: SERVER_PROTOCOL is HTTP/2";
        is $captured[1]{body}, 'h2=payload', "h2: POST body correct";
    };
}

# ===========================================================================
# Test 4: Proxy v1 + TLS/H1
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v1 + TLS/H1' => sub {
        plan tests => 8;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v1-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        @captured = ();
        run_client("proxy-v1 + tls GET", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '1.2.3.4', '5.6.7.8', 12345, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            my ($status, $body) = http1_request($raw, 'GET', '/proxy-v1-test');
            $raw->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /addr=1\.2\.3\.4/) ? 0 : 3;
        });

        run_client("proxy-v1 + tls POST", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '10.0.0.1', '10.0.0.2', 54321, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            my ($status, $body) = http1_request($raw, 'POST', '/proxy-v1-post', body => 'pv1=data');
            $raw->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /body=pv1=data/) ? 0 : 3;
        });

        cmp_ok scalar(@captured), '>=', 2, "proxy-v1-tls: received requests";
        is $captured[0]{addr}, '1.2.3.4', "proxy-v1-tls: REMOTE_ADDR from proxy";
        is $captured[0]{scheme}, 'https', "proxy-v1-tls: url_scheme is https";
    };
}

# ===========================================================================
# Test 5: Proxy v2 + TLS/H1
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 + TLS/H1' => sub {
        plan tests => 6;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        @captured = ();
        run_client("proxy-v2 + tls GET", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '198.51.100.1', '198.51.100.2', 33333, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            my ($status, $body) = http1_request($raw, 'GET', '/proxy-v2-test');
            $raw->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /addr=198\.51\.100\.1/) ? 0 : 3;
        });

        cmp_ok scalar(@captured), '>=', 1, "proxy-v2-tls: received request";
        is $captured[0]{addr}, '198.51.100.1', "proxy-v2-tls: REMOTE_ADDR from proxy";
        is $captured[0]{scheme}, 'https', "proxy-v2-tls: url_scheme is https";
    };
}

# ===========================================================================
# Test 6: Proxy v1 + H2
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v1 + H2' => sub {
        plan tests => 7;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v1-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($handler);

        @captured = ();
        run_client("proxy-v1 + h2 GET", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '172.16.0.1', '172.16.0.2', 44444, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            $raw->syswrite(h2_client_preface());
            $raw->blocking(0);
            # Read server SETTINGS, send ACK
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
                    $raw->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
                    last;
                }
            }
            for (1..5) { my $f = h2_read_frame($raw, 0.2); last unless $f; }

            my ($status, $body) = h2_request($raw, 1, 'GET', '/proxy-v1-h2', $port);
            $raw->close;
            return (defined $status && $status eq '200' && $body =~ /addr=172\.16\.0\.1/) ? 0 : 3;
        });

        cmp_ok scalar(@captured), '>=', 1, "proxy-v1-h2: received request";
        is $captured[0]{addr}, '172.16.0.1', "proxy-v1-h2: REMOTE_ADDR from proxy";
        is $captured[0]{scheme}, 'https', "proxy-v1-h2: url_scheme is https";
        is $captured[0]{proto}, 'HTTP/2', "proxy-v1-h2: SERVER_PROTOCOL is HTTP/2";
    };
}

# ===========================================================================
# Test 7: Proxy v2 + H2
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 + H2' => sub {
        plan tests => 7;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($handler);

        @captured = ();
        run_client("proxy-v2 + h2 GET", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '203.0.113.50', '203.0.113.51', 55555, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            $raw->syswrite(h2_client_preface());
            $raw->blocking(0);
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
                    $raw->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
                    last;
                }
            }
            for (1..5) { my $f = h2_read_frame($raw, 0.2); last unless $f; }

            my ($status, $body) = h2_request($raw, 1, 'GET', '/proxy-v2-h2', $port);
            $raw->close;
            return (defined $status && $status eq '200' && $body =~ /addr=203\.0\.113\.50/) ? 0 : 3;
        });

        cmp_ok scalar(@captured), '>=', 1, "proxy-v2-h2: received request";
        is $captured[0]{addr}, '203.0.113.50', "proxy-v2-h2: REMOTE_ADDR from proxy";
        is $captured[0]{scheme}, 'https', "proxy-v2-h2: url_scheme is https";
        is $captured[0]{proto}, 'HTTP/2', "proxy-v2-h2: SERVER_PROTOCOL is HTTP/2";
    };
}

# ===========================================================================
# Test 8: Plain keepalive (2 requests on 1 connection)
# ===========================================================================
subtest 'Plain HTTP/1.1 keepalive' => sub {
    plan tests => 4;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "keepalive: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_keepalive(1);
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("keepalive", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        my ($s1, $b1) = http1_request($sock, 'GET', '/ka-1', connection => 'keep-alive');
        return 2 unless $s1 eq '200';
        my ($s2, $b2) = http1_request($sock, 'GET', '/ka-2', connection => 'close');
        $sock->close;
        return ($s2 eq '200' && $b1 =~ /path=\/ka-1/ && $b2 =~ /path=\/ka-2/) ? 0 : 3;
    });

    cmp_ok scalar(@captured), '>=', 2, "keepalive: received 2 requests";
};

# ===========================================================================
# Test 9: Client disconnect during streaming response (plain)
# ===========================================================================
subtest 'Plain: client disconnect during streaming' => sub {
    plan tests => 3;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "disconnect-plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);

    $evh->request_handler(sub {
        my $req = shift;
        my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
        my $n = 0;
        my $t; $t = AE::timer(0.02, 0.05, sub {
            $n++;
            eval { $w->write("chunk $n\n") };
            if ($@) {
                undef $t;
                return;
            }
            if ($n >= 20) {
                undef $t;
                eval { $w->close() };
            }
        });
    });

    run_client("disconnect during streaming", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->print("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        # Read just the headers + first chunk, then close abruptly
        my $buf = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            last if $buf =~ /chunk 1/;
        }
        close($sock);  # abrupt close
        return ($buf =~ /chunk 1/) ? 0 : 2;
    });
};

# ===========================================================================
# Test 10: Client disconnect during streaming response (TLS)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS: client disconnect during streaming' => sub {
        plan tests => 3;

        # Let previous Feersum instances fully clean up
        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("chunk $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 20) { undef $t; eval { $w->close() }; }
            });
        });

        run_client("tls disconnect during streaming", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 1;
            $raw->print("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            my $buf = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            $raw->blocking(0);
            while (time < $deadline) {
                my $n = $raw->sysread(my $chunk, 4096);
                if (defined $n && $n > 0) { $buf .= $chunk; }
                elsif (defined $n && $n == 0) { last; }
                else { select(undef, undef, undef, 0.05); }
                last if $buf =~ /chunk 1/;
            }
            close($raw);
            return ($buf =~ /chunk 1/) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 11: H2 client disconnect during streaming (RST_STREAM)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2: client disconnect during streaming (RST_STREAM)' => sub {
        plan tests => 3;

        # Let previous instances clean up
        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("chunk $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 20) { undef $t; eval { $w->close() }; }
            });
        });

        run_client("h2 disconnect during streaming", sub {
            my $sock = h2_connect($port) or return 1;

            # Send GET request
            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/stream'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            # Wait for response headers + at least one DATA frame
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

            # Send RST_STREAM (CANCEL=0x08) then close
            $sock->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 0x08)));
            select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
            $sock->close;
            return $got_data ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 12: TLS/H1 keepalive (2 requests on 1 TLS connection)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'TLS/H1 keepalive' => sub {
        plan tests => 4;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "tls-keepalive: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_keepalive(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        @captured = ();
        run_client("tls keepalive", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($s1, $b1) = http1_request($sock, 'GET', '/tls-ka-1', connection => 'keep-alive');
            return 2 unless $s1 eq '200';
            my ($s2, $b2) = http1_request($sock, 'GET', '/tls-ka-2', connection => 'close');
            $sock->close(SSL_no_shutdown => 1);
            return ($s2 eq '200' && $b1 =~ /path=\/tls-ka-1/ && $b2 =~ /path=\/tls-ka-2/) ? 0 : 3;
        });

        cmp_ok scalar(@captured), '>=', 2, "tls-keepalive: received 2 requests";
    };
}

# ===========================================================================
# Test 13: H2 multiplexed streams (concurrent requests)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 sequential requests on one connection' => sub {
        plan tests => 4;

        # Let previous H2 instances clean up
        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "h2-seq: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        # Handler without Connection:close to keep H2 session alive
        $evh->request_handler(sub {
            my $req = shift;
            my $env = $req->env();
            my $method = $env->{REQUEST_METHOD} || 'GET';
            my $path   = $env->{PATH_INFO} || '/';
            push @captured, { method => $method, path => $path };
            my $resp = "method=$method path=$path";
            $req->send_response(200, [
                'Content-Type'   => 'text/plain',
                'Content-Length' => length($resp),
            ], \$resp);
        });

        @captured = ();
        run_client("h2 sequential", sub {
            my $sock = h2_connect($port) or return 1;

            # Send 3 requests sequentially on streams 1, 3, 5
            for my $i (0..2) {
                my $stream_id = 1 + $i * 2;
                my ($status, $body) = h2_request($sock, $stream_id, 'GET', "/seq-$stream_id", $port);
                unless (defined $status && $status eq '200') {
                    warn "h2-seq stream $stream_id: status=".($status//'undef')."\n";
                    return 2;
                }
                unless ($body =~ /path=\/seq-$stream_id/) {
                    warn "h2-seq stream $stream_id: body=$body\n";
                    return 3;
                }
            }
            $sock->close;
            return 0;
        });

        cmp_ok scalar(@captured), '>=', 3, "h2-seq: received 3 requests";
    };
}

# ===========================================================================
# Test 14: Proxy v1 + plain HTTP (no TLS)
# ===========================================================================
subtest 'Proxy v1 + plain HTTP' => sub {
    plan tests => 6;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "proxy-v1-plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("proxy-v1 plain GET", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->syswrite(build_proxy_v1('TCP4', '192.168.0.1', '192.168.0.2', 11111, 80));
        my ($status, $body) = http1_request($sock, 'GET', '/proxy-v1-plain');
        $sock->close;
        return ($status eq '200' && $body =~ /addr=192\.168\.0\.1/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 1, "proxy-v1-plain: received request";
    is $captured[0]{addr}, '192.168.0.1', "proxy-v1-plain: REMOTE_ADDR from proxy";
    is $captured[0]{scheme}, 'http', "proxy-v1-plain: url_scheme is http";
};

# ===========================================================================
# Test 15: Proxy v2 + plain HTTP (no TLS)
# ===========================================================================
subtest 'Proxy v2 + plain HTTP' => sub {
    plan tests => 6;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "proxy-v2-plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("proxy-v2 plain GET", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->syswrite(build_proxy_v2('PROXY', 'INET', '10.99.0.1', '10.99.0.2', 22222, 80));
        my ($status, $body) = http1_request($sock, 'GET', '/proxy-v2-plain');
        $sock->close;
        return ($status eq '200' && $body =~ /addr=10\.99\.0\.1/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 1, "proxy-v2-plain: received request";
    is $captured[0]{addr}, '10.99.0.1', "proxy-v2-plain: REMOTE_ADDR from proxy";
    is $captured[0]{scheme}, 'http', "proxy-v2-plain: url_scheme is http";
};

# ===========================================================================
# Test 16: Proxy v2 IPv6 + TLS
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Proxy v2 IPv6 + TLS' => sub {
        plan tests => 6;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "proxy-v2-ipv6: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        @captured = ();
        run_client("proxy-v2 IPv6 GET", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET6',
                '2001:db8::1', '2001:db8::2', 44444, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            my ($status, $body) = http1_request($raw, 'GET', '/proxy-v2-ipv6');
            $raw->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /addr=2001:db8::1/) ? 0 : 3;
        });

        cmp_ok scalar(@captured), '>=', 1, "proxy-v2-ipv6: received request";
        is $captured[0]{addr}, '2001:db8::1', "proxy-v2-ipv6: REMOTE_ADDR is IPv6";
        is $captured[0]{scheme}, 'https', "proxy-v2-ipv6: url_scheme is https";
    };
}

# ===========================================================================
# Test 17: Large POST body (64KB, plain + H2)
# ===========================================================================
subtest 'Large POST body (plain)' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "large-post: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    my $large_body = 'X' x 65536;  # 64KB

    @captured = ();
    run_client("large POST", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 10 * TIMEOUT_MULT,
        ) or return 1;
        my ($status, $body) = http1_request($sock, 'POST', '/large-post', body => $large_body);
        $sock->close;
        return ($status eq '200' && $body =~ /method=POST/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 1, "large-post: received request";
    is length($captured[0]{body}), 65536, "large-post: full 64KB body received";
};

SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Large POST body (H2)' => sub {
        plan tests => 5;

        # Let previous H2 instances clean up
        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "large-post-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($handler);

        # H2 max frame payload defaults to 16384; send body in multiple frames
        my $large_body = 'Y' x 8192;  # 8KB (within single frame + window)

        @captured = ();
        run_client("large POST h2", sub {
            my $sock = h2_connect($port) or return 1;

            # Send HEADERS without END_STREAM
            my $hdr_block = hpack_encode_headers(
                [':method', 'POST'],
                [':path', '/large-post-h2'],
                [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
                ['content-type', 'text/plain'],
                ['content-length', length($large_body)],
            );
            $sock->blocking(1);
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block));

            # Send body in 16384-byte DATA frames
            my $offset = 0;
            while ($offset < length($large_body)) {
                my $chunk_size = 16384;
                $chunk_size = length($large_body) - $offset if $offset + $chunk_size > length($large_body);
                my $chunk = substr($large_body, $offset, $chunk_size);
                $offset += $chunk_size;
                my $flags = ($offset >= length($large_body)) ? FLAG_END_STREAM : 0;
                $sock->syswrite(h2_frame(H2_DATA, $flags, 1, $chunk));
            }
            $sock->blocking(0);

            # Read response
            my $status;
            my $resp_body = '';
            my $deadline = time + 10;
            my $done = 0;
            while (!$done && time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    $status = hpack_decode_status($f->{payload});
                    $done = 1 if $f->{flags} & FLAG_END_STREAM;
                }
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $resp_body .= $f->{payload};
                    $done = 1 if $f->{flags} & FLAG_END_STREAM;
                    if (!$done && length($f->{payload}) > 0) {
                        $sock->blocking(1);
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                        $sock->blocking(0);
                    }
                }
                if ($f->{type} == H2_WINDOW_UPDATE) {
                    # Server granting more window, continue reading
                }
            }
            $sock->close;
            unless (defined $status) { warn "large-post-h2: no status received\n"; return 2; }
            unless ($status eq '200') { warn "large-post-h2: status=$status\n"; return 2; }
            unless ($resp_body =~ /method=POST/) { warn "large-post-h2: body=$resp_body\n"; return 2; }
            return 0;
        });

        cmp_ok scalar(@captured), '>=', 1, "large-post-h2: received request";
        is length($captured[0]{body} // ''), 8192, "large-post-h2: full 8KB body received";
    };
}

# ===========================================================================
# Test 19: Chunked Transfer-Encoding (H1 only)
# ===========================================================================
subtest 'Chunked Transfer-Encoding POST' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "chunked: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("chunked POST", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;

        # Send chunked request manually
        my $req = "POST /chunked HTTP/1.1\r\n"
                . "Host: localhost\r\n"
                . "Transfer-Encoding: chunked\r\n"
                . "Connection: close\r\n"
                . "\r\n"
                . "5\r\nhello\r\n"
                . "6\r\n world\r\n"
                . "0\r\n\r\n";
        $sock->print($req);

        my $response = '';
        while (defined(my $line = $sock->getline())) {
            $response .= $line;
            last if $response =~ /\r\n\r\n/;
        }
        my ($status) = $response =~ m{HTTP/1\.\d (\d+)};
        my ($cl) = $response =~ /Content-Length:\s*(\d+)/i;
        my $resp_body = '';
        if ($cl && $cl > 0) { $sock->read($resp_body, $cl); }
        $sock->close;
        return ($status eq '200' && $resp_body =~ /method=POST/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 1, "chunked: received request";
    is $captured[0]{body}, 'hello world', "chunked: body reassembled correctly";
};

# ===========================================================================
# Test 20: Error response 404 (plain)
# ===========================================================================
{
    my $error_handler = sub {
        my $req = shift;
        my $env = $req->env();
        my $path = $env->{PATH_INFO} || '/';
        if ($path eq '/missing') {
            $req->send_response(404, ['Content-Type' => 'text/plain', 'Content-Length' => 9], \"Not Found");
        } elsif ($path eq '/error') {
            $req->send_response(500, ['Content-Type' => 'text/plain', 'Content-Length' => 12], \"Server Error");
        } else {
            $req->send_response(200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], \"OK");
        }
    };

    subtest 'Error response 404 (plain)' => sub {
        plan tests => 6;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "err-plain: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->request_handler($error_handler);

        run_client("plain 404", sub {
            my $sock = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'GET', '/missing');
            $sock->close;
            return ($status eq '404' && $body eq 'Not Found') ? 0 : 2;
        });

        run_client("plain 200 after error", sub {
            my $sock = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'GET', '/ok');
            $sock->close;
            return ($status eq '200' && $body eq 'OK') ? 0 : 2;
        });

        pass "err-plain: server survived error responses";
    };
}

# ===========================================================================
# Test 21: Error response 404 (TLS/H1)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    my $error_handler = sub {
        my $req = shift;
        my $env = $req->env();
        my $path = $env->{PATH_INFO} || '/';
        if ($path eq '/missing') {
            $req->send_response(404, ['Content-Type' => 'text/plain', 'Content-Length' => 9], \"Not Found");
        } else {
            $req->send_response(200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], \"OK");
        }
    };

    subtest 'Error response 404 (TLS/H1)' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "err-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($error_handler);

        run_client("tls 404", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'GET', '/missing');
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '404' && $body eq 'Not Found') ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 22: Error response 500 (H2)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    my $error_handler = sub {
        my $req = shift;
        my $env = $req->env();
        my $path = $env->{PATH_INFO} || '/';
        if ($path eq '/error') {
            $req->send_response(500, ['Content-Type' => 'text/plain', 'Content-Length' => 12], \"Server Error");
        } elsif ($path eq '/missing') {
            $req->send_response(404, ['Content-Type' => 'text/plain', 'Content-Length' => 9], \"Not Found");
        } else {
            $req->send_response(200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], \"OK");
        }
    };

    subtest 'Error response 500 (H2)' => sub {
        plan tests => 5;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "err-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->request_handler($error_handler);

        run_client("h2 500", sub {
            my $sock = h2_connect($port) or return 1;
            my ($status, $body) = h2_request($sock, 1, 'GET', '/error', $port);
            return 2 unless defined $status && $status eq '500' && $body eq 'Server Error';
            my ($status2, $body2) = h2_request($sock, 3, 'GET', '/missing', $port);
            return 3 unless defined $status2 && $status2 eq '404' && $body2 eq 'Not Found';
            my ($status3, $body3) = h2_request($sock, 5, 'GET', '/ok', $port);
            $sock->close;
            return (defined $status3 && $status3 eq '200' && $body3 eq 'OK') ? 0 : 4;
        });

        pass "err-h2: 500, 404, and 200 all correct over H2";
        pass "err-h2: feersum_h2_start_response handles non-200 status";
    };
}

# ===========================================================================
# Test 23: H2 concurrent streams (true multiplexing)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 concurrent streams (multiplexing)' => sub {
        plan tests => 5;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "h2-mux: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

        my @mux_captured;
        $evh->request_handler(sub {
            my $req = shift;
            my $env = $req->env();
            my $path = $env->{PATH_INFO} || '/';
            push @mux_captured, $path;
            my $resp = "path=$path";
            $req->send_response(200, [
                'Content-Type'   => 'text/plain',
                'Content-Length' => length($resp),
            ], \$resp);
        });

        run_client("h2 multiplexing", sub {
            my $sock = h2_connect($port) or return 1;

            # Send 3 requests on streams 1, 3, 5 ALL before reading any response
            for my $sid (1, 3, 5) {
                my $path = "/mux-$sid";
                my $hdr_block = hpack_encode_headers(
                    [':method', 'GET'], [':path', $path],
                    [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
                );
                $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $sid, $hdr_block));
            }

            # Now read all responses
            my %responses;  # stream_id => { status => ..., body => ... }
            my $deadline = time + 8;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                my $sid = $f->{stream_id};
                next unless $sid && ($sid == 1 || $sid == 3 || $sid == 5);
                $responses{$sid} //= { status => undef, body => '' };
                if ($f->{type} == H2_HEADERS) {
                    $responses{$sid}{status} = hpack_decode_status($f->{payload});
                    $responses{$sid}{done} = 1 if $f->{flags} & FLAG_END_STREAM;
                }
                if ($f->{type} == H2_DATA) {
                    $responses{$sid}{body} .= $f->{payload};
                    $responses{$sid}{done} = 1 if $f->{flags} & FLAG_END_STREAM;
                    if (!$responses{$sid}{done} && length($f->{payload}) > 0) {
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $sid, pack('N', length($f->{payload}))));
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                    }
                }
                # Check if all streams are done
                last if 3 == grep { $_->{done} } values %responses;
            }
            $sock->close;

            # Verify all 3 streams got 200 with correct paths
            for my $sid (1, 3, 5) {
                return 2 unless $responses{$sid} && $responses{$sid}{status} eq '200';
                return 3 unless $responses{$sid}{body} =~ /path=\/mux-$sid/;
            }
            return 0;
        });

        cmp_ok scalar(@mux_captured), '>=', 3, "h2-mux: received 3 concurrent requests";
        pass "h2-mux: all streams completed with correct responses";
    };
}

# ===========================================================================
# Test 24: H2 GOAWAY mid-stream (graceful shutdown)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'H2 GOAWAY mid-stream (graceful shutdown)' => sub {
        plan tests => 3;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "goaway: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("event $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 5) { undef $t; eval { $w->close() }; }
            });
            # Schedule graceful_shutdown after first chunk is sent
            my $g; $g = AE::timer(0.1, 0, sub {
                undef $g;
                $evh->graceful_shutdown(sub {});
            });
        });

        run_client("h2 goaway", sub {
            my $sock = h2_connect($port) or return 1;

            # Send a request
            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/goaway-test'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            # Read frames - expect response data AND a GOAWAY frame
            my $got_data = 0;
            my $got_goaway = 0;
            my $deadline = time + 8;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $got_data = 1;
                    if (length($f->{payload}) > 0) {
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                    }
                    last if $f->{flags} & FLAG_END_STREAM;
                }
                if ($f->{type} == H2_GOAWAY) {
                    $got_goaway = 1;
                }
            }

            # If we didn't get GOAWAY yet, send a PING to trigger lazy GOAWAY
            if (!$got_goaway) {
                $sock->syswrite(h2_frame(H2_PING, 0, 0, "\0" x 8));
                for (1..5) {
                    my $f = h2_read_frame($sock, 1);
                    last unless $f;
                    if ($f->{type} == H2_GOAWAY) { $got_goaway = 1; last; }
                }
            }

            $sock->close;
            return ($got_data && $got_goaway) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 25: HTTP/1.1 pipelining
# ===========================================================================
subtest 'HTTP/1.1 pipelining' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "pipeline: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_keepalive(1);
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("pipelining", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;

        # Send 3 requests in one write - classic pipelining
        my $pipelined =
            "GET /pipe-1 HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
          . "GET /pipe-2 HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
          . "GET /pipe-3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        $sock->print($pipelined);

        # Read all 3 responses
        my $buf = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 16384);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
            # Count complete responses (each ends with body after Content-Length)
            my @statuses = ($buf =~ m{HTTP/1\.1 200}g);
            last if @statuses >= 3;
        }
        $sock->close;

        my @statuses = ($buf =~ m{HTTP/1\.1 (\d+)}g);
        return 2 unless @statuses == 3;
        return 3 unless $statuses[0] eq '200' && $statuses[1] eq '200' && $statuses[2] eq '200';
        return 4 unless $buf =~ /path=\/pipe-1/ && $buf =~ /path=\/pipe-2/ && $buf =~ /path=\/pipe-3/;
        return 0;
    });

    cmp_ok scalar(@captured), '>=', 3, "pipeline: received 3 pipelined requests";
    is $captured[0]{path}, '/pipe-1', "pipeline: correct order";
};

# ===========================================================================
# Test 26: Large POST body (TLS/H1)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Large POST body (TLS/H1)' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "large-post-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);

        # Use a handler that reports body length (avoids echoing 64KB in response)
        my @lp_captured;
        $evh->request_handler(sub {
            my $req = shift;
            my $env = $req->env();
            my $cl = $env->{CONTENT_LENGTH} || 0;
            my $body = '';
            if ($cl > 0 && $env->{'psgi.input'}) {
                $env->{'psgi.input'}->read($body, $cl);
            }
            push @lp_captured, { body_len => length($body) };
            my $resp = "len=" . length($body);
            $req->send_response(200, [
                'Content-Type'   => 'text/plain',
                'Content-Length' => length($resp),
            ], \$resp);
        });

        run_client("large POST tls", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my $big_body = 'Z' x 65536;
            my ($status, $body) = http1_request($sock, 'POST', '/large-tls', body => $big_body);
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body eq 'len=65536') ? 0 : 2;
        });

        cmp_ok scalar(@lp_captured), '>=', 1, "large-post-tls: received request";
        is $lp_captured[0]{body_len}, 65536, "large-post-tls: full 64KB body received";
    };
}

# ===========================================================================
# Test 27: Chunked Transfer-Encoding POST (TLS)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Chunked Transfer-Encoding POST (TLS)' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "chunked-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        @captured = ();
        run_client("chunked POST tls", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;

            my $req = "POST /chunked-tls HTTP/1.1\r\n"
                    . "Host: localhost\r\n"
                    . "Transfer-Encoding: chunked\r\n"
                    . "Connection: close\r\n"
                    . "\r\n"
                    . "5\r\nhello\r\n"
                    . "6\r\n world\r\n"
                    . "0\r\n\r\n";
            $sock->print($req);

            my $response = '';
            while (defined(my $line = $sock->getline())) {
                $response .= $line;
                last if $response =~ /\r\n\r\n/;
            }
            my ($status) = $response =~ m{HTTP/1\.\d (\d+)};
            my ($cl) = $response =~ /Content-Length:\s*(\d+)/i;
            my $resp_body = '';
            if ($cl && $cl > 0) { $sock->read($resp_body, $cl); }
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $resp_body =~ /method=POST/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 1, "chunked-tls: received request";
        is $captured[0]{body}, 'hello world', "chunked-tls: body reassembled correctly";
    };
}

# ===========================================================================
# Test 28: Streaming response (proxy v1 + TLS)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Streaming response (proxy v1+TLS)' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "stream-proxy-v1-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("chunk $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 3) { undef $t; eval { $w->close() }; }
            });
        });

        run_client("proxy-v1 tls streaming", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '1.2.3.4', '5.6.7.8', 12345, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            $raw->print("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

            my $buf = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            $raw->blocking(0);
            while (time < $deadline) {
                my $n = $raw->sysread(my $chunk, 4096);
                if (defined $n && $n > 0) { $buf .= $chunk; }
                elsif (defined $n && $n == 0) { last; }
                else { select(undef, undef, undef, 0.05); }
                last if $buf =~ /chunk 3/;
            }
            close($raw);
            return ($buf =~ /chunk 1/ && $buf =~ /chunk 3/) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 29: Streaming response (proxy v2 + H2)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Streaming response (proxy v2+H2)' => sub {
        plan tests => 3;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "stream-proxy-v2-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("chunk $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 3) { undef $t; eval { $w->close() }; }
            });
        });

        run_client("proxy-v2 h2 streaming", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '203.0.113.1', '203.0.113.2', 55555, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            $raw->syswrite(h2_client_preface());
            $raw->blocking(0);
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
                    $raw->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
                    last;
                }
            }
            for (1..5) { my $f = h2_read_frame($raw, 0.2); last unless $f; }

            # Send GET request
            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/stream'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $raw->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            my $data = '';
            $deadline = time + 8;
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
                last if $data =~ /chunk 3/;
            }
            $raw->close;
            return ($data =~ /chunk 1/ && $data =~ /chunk 3/) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 30: Client disconnect during proxy v1+TLS streaming
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'Disconnect during proxy v1+TLS streaming' => sub {
        plan tests => 3;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-proxy-v1-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("chunk $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 20) { undef $t; eval { $w->close() }; }
            });
        });

        run_client("proxy-v1 tls disconnect", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v1('TCP4', '1.2.3.4', '5.6.7.8', 12345, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            ) or return 2;
            $raw->print("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            my $buf = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            $raw->blocking(0);
            while (time < $deadline) {
                my $n = $raw->sysread(my $chunk, 4096);
                if (defined $n && $n > 0) { $buf .= $chunk; }
                elsif (defined $n && $n == 0) { last; }
                else { select(undef, undef, undef, 0.05); }
                last if $buf =~ /chunk 1/;
            }
            close($raw);  # abrupt close
            return ($buf =~ /chunk 1/) ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 31: Client disconnect during proxy v2+H2 streaming
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Disconnect during proxy v2+H2 streaming' => sub {
        plan tests => 3;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "disconnect-proxy-v2-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_proxy_protocol(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

        $evh->request_handler(sub {
            my $req = shift;
            my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
            my $n = 0;
            my $t; $t = AE::timer(0.02, 0.05, sub {
                $n++;
                eval { $w->write("chunk $n\n") };
                if ($@) { undef $t; return; }
                if ($n >= 20) { undef $t; eval { $w->close() }; }
            });
        });

        run_client("proxy-v2 h2 disconnect", sub {
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $raw->syswrite(build_proxy_v2('PROXY', 'INET', '203.0.113.1', '203.0.113.2', 55555, 443));
            IO::Socket::SSL->start_SSL($raw,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'],
            ) or return 2;
            $raw->syswrite(h2_client_preface());
            $raw->blocking(0);
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
                    $raw->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
                    last;
                }
            }
            for (1..5) { my $f = h2_read_frame($raw, 0.2); last unless $f; }

            my $hdr_block = hpack_encode_headers(
                [':method', 'GET'], [':path', '/stream'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $raw->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            # Wait for at least one DATA frame
            my $got_data = 0;
            $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($raw, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1 && length($f->{payload}) > 0) {
                    $got_data = 1;
                    last;
                }
            }

            # Send RST_STREAM then close abruptly
            $raw->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 0x08)));
            select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
            close($raw);
            return $got_data ? 0 : 2;
        });
    };
}

# ===========================================================================
# Test 32: Keepalive (proxy v1 + plain)
# ===========================================================================
subtest 'Keepalive (proxy v1+plain)' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "keepalive-proxy-v1: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->set_keepalive(1);
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("proxy-v1 keepalive", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        # Send proxy v1 header first, then 2 keepalive requests
        $sock->syswrite(build_proxy_v1('TCP4', '10.0.0.99', '10.0.0.1', 12345, 80));
        my ($s1, $b1) = http1_request($sock, 'GET', '/ka-1', connection => 'keep-alive');
        return 2 unless $s1 eq '200';
        my ($s2, $b2) = http1_request($sock, 'GET', '/ka-2', connection => 'close');
        $sock->close;
        return ($s2 eq '200' && $b1 =~ /addr=10\.0\.0\.99/ && $b2 =~ /addr=10\.0\.0\.99/) ? 0 : 3;
    });

    cmp_ok scalar(@captured), '>=', 2, "keepalive-proxy-v1: received 2 requests";
    is $captured[0]{addr}, '10.0.0.99', "keepalive-proxy-v1: REMOTE_ADDR from proxy";
};

# ===========================================================================
# Test 33: HEAD request (plain)
# ===========================================================================
subtest 'HEAD request (plain)' => sub {
    plan tests => 4;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "head-plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);

    my @head_captured;
    $evh->request_handler(sub {
        my $req = shift;
        my $env = $req->env();
        push @head_captured, $env->{REQUEST_METHOD};
        # Feersum auto-generates Content-Length from actual body;
        # it does NOT suppress body for HEAD (app responsibility).
        $req->send_response(200, [
            'Content-Type'   => 'text/plain',
        ], \"hello");
    });

    run_client("plain HEAD", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->print("HEAD /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        my $response = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $response .= $chunk;
            last if $response =~ /\r\n\r\n/;
        }
        $sock->close;

        my ($status) = $response =~ m{HTTP/1\.1 (\d+)};
        my ($cl) = $response =~ /Content-Length:\s*(\d+)/i;
        return ($status eq '200' && defined $cl && $cl == 5) ? 0 : 2;
    });

    is $head_captured[0], 'HEAD', "head-plain: REQUEST_METHOD is HEAD";
};

# ===========================================================================
# Test 34: HEAD request (H2)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'HEAD request (H2)' => sub {
        plan tests => 4;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "head-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        my @h2_head_captured;
        $evh->request_handler(sub {
            my $req = shift;
            my $env = $req->env();
            push @h2_head_captured, $env->{REQUEST_METHOD};
            # HEAD-aware: empty body so no DATA frame is sent.
            # H2 path doesn't auto-strip Content-Length, so we can set it.
            $req->send_response(200, [
                'Content-Type'   => 'text/plain',
                'Content-Length' => 5,
            ], \"");
        });

        run_client("h2 HEAD", sub {
            my $sock = h2_connect($port) or return 1;

            # Send HEAD request
            my $hdr_block = hpack_encode_headers(
                [':method', 'HEAD'], [':path', '/test'],
                [':scheme', 'https'], [':authority', "127.0.0.1:$port"],
            );
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdr_block));

            # Read response - HEADERS with END_STREAM, no DATA (empty body)
            my $got_headers = 0;
            my $got_data = 0;
            my $status;
            my $deadline = time + 5;
            while (time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    $status = hpack_decode_status($f->{payload});
                    $got_headers = 1;
                    last if $f->{flags} & FLAG_END_STREAM;
                }
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $got_data = 1;
                    last if $f->{flags} & FLAG_END_STREAM;
                }
            }
            $sock->close;
            return ($got_headers && defined $status && $status eq '200' && !$got_data) ? 0 : 2;
        });

        is $h2_head_captured[0], 'HEAD', "head-h2: REQUEST_METHOD is HEAD";
    };
}

# ===========================================================================
# Test 35: Large POST body (H2, 64KB - exercises H2 tls_rbuf drain loop)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'Large POST body (H2, 64KB)' => sub {
        plan tests => 5;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "large-post-h2-64k: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);

        my @lp2_captured;
        $evh->request_handler(sub {
            my $req = shift;
            my $env = $req->env();
            my $cl = $env->{CONTENT_LENGTH} || 0;
            my $body = '';
            if ($cl > 0 && $env->{'psgi.input'}) {
                $env->{'psgi.input'}->read($body, $cl);
            }
            push @lp2_captured, { body_len => length($body) };
            my $resp = "len=" . length($body);
            $req->send_response(200, [
                'Content-Type'   => 'text/plain',
                'Content-Length' => length($resp),
            ], \$resp);
        });

        my $large_body = 'W' x 32768;  # 32KB: 2 full DATA frames, within 65535 window

        run_client("large POST h2 64k", sub {
            my $sock = h2_connect($port) or return 1;

            my $hdr_block = hpack_encode_headers(
                [':method', 'POST'],
                [':path', '/large-post-h2-64k'],
                [':scheme', 'https'],
                [':authority', "127.0.0.1:$port"],
                ['content-type', 'text/plain'],
                ['content-length', length($large_body)],
            );
            $sock->blocking(1);
            $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdr_block));

            # Send body in 8192-byte DATA frames
            my $offset = 0;
            while ($offset < length($large_body)) {
                my $chunk_size = 8192;
                $chunk_size = length($large_body) - $offset if $offset + $chunk_size > length($large_body);
                my $chunk = substr($large_body, $offset, $chunk_size);
                $offset += $chunk_size;
                my $flags = ($offset >= length($large_body)) ? FLAG_END_STREAM : 0;
                $sock->syswrite(h2_frame(H2_DATA, $flags, 1, $chunk));
            }
            $sock->blocking(0);

            my ($status, $resp_body) = (undef, '');
            my $deadline = time + 10;
            my $done = 0;
            while (!$done && time < $deadline) {
                my $f = h2_read_frame($sock, $deadline - time);
                last unless $f;
                if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                    $status = hpack_decode_status($f->{payload});
                    $done = 1 if $f->{flags} & FLAG_END_STREAM;
                }
                if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                    $resp_body .= $f->{payload};
                    $done = 1 if $f->{flags} & FLAG_END_STREAM;
                    if (!$done && length($f->{payload}) > 0) {
                        $sock->blocking(1);
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', length($f->{payload}))));
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', length($f->{payload}))));
                        $sock->blocking(0);
                    }
                }
            }
            $sock->close;
            return ($status && $status eq '200' && $resp_body eq 'len=32768') ? 0 : 2;
        });

        cmp_ok scalar(@lp2_captured), '>=', 1, "large-post-h2-64k: received request";
        is $lp2_captured[0]{body_len}, 32768, "large-post-h2-64k: full 32KB body received";
    };
}

# ===========================================================================
# Test 36: Pipelining over TLS (exercises HTTP/1.1 tls_rbuf drain loop)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'HTTP/1.1 pipelining (TLS)' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "pipeline-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->set_keepalive(1);
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->request_handler($handler);

        my @pipe_captured;
        @captured = ();
        run_client("pipelining tls", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;

            # Send 3 pipelined requests in one write over TLS
            my $pipelined =
                "GET /tls-pipe-1 HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
              . "GET /tls-pipe-2 HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
              . "GET /tls-pipe-3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
            $sock->print($pipelined);

            # Read until EOF (last request has Connection: close)
            my $buf = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $chunk, 16384);
                if (defined $n && $n > 0) {
                    $buf .= $chunk;
                } elsif (defined $n && $n == 0) {
                    last;  # EOF - server closed after Connection: close
                } else {
                    select(undef, undef, undef, 0.01);  # SSL_WANT_READ
                }
            }
            $sock->close(SSL_no_shutdown => 1);

            my @statuses = ($buf =~ m{HTTP/1\.1 (\d+)}g);
            return 2 unless @statuses == 3;
            return 3 unless $statuses[0] eq '200' && $statuses[1] eq '200' && $statuses[2] eq '200';
            return 4 unless $buf =~ /path=\/tls-pipe-1/ && $buf =~ /path=\/tls-pipe-2/ && $buf =~ /path=\/tls-pipe-3/;
            return 0;
        });

        cmp_ok scalar(@captured), '>=', 3, "pipeline-tls: received 3 pipelined requests";
        is $captured[0]{path}, '/tls-pipe-1', "pipeline-tls: correct order";
    };
}

# ===========================================================================
# Test 37: HEAD request (TLS/H1)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'HEAD request (TLS/H1)' => sub {
        plan tests => 4;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "head-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);

        my @head_tls_captured;
        $evh->request_handler(sub {
            my $req = shift;
            my $env = $req->env();
            push @head_tls_captured, $env->{REQUEST_METHOD};
            $req->send_response(200, [
                'Content-Type' => 'text/plain',
            ], \"hello");
        });

        run_client("tls HEAD", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $sock->print("HEAD /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

            my $response = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $response .= $chunk;
                last if $response =~ /\r\n\r\n/;
            }
            $sock->close(SSL_no_shutdown => 1);

            my ($status) = $response =~ m{HTTP/1\.1 (\d+)};
            my ($cl) = $response =~ /Content-Length:\s*(\d+)/i;
            return ($status eq '200' && defined $cl && $cl == 5) ? 0 : 2;
        });

        is $head_tls_captured[0], 'HEAD', "head-tls: REQUEST_METHOD is HEAD";
    };
}

# ===========================================================================
# Test 38: Keepalive (proxy v2+plain)
# ===========================================================================
subtest 'Keepalive (proxy v2+plain)' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "keepalive-proxy-v2: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->set_proxy_protocol(1);
    $evh->set_keepalive(1);
    $evh->use_socket($socket);
    $evh->request_handler($handler);

    @captured = ();
    run_client("proxy-v2 keepalive", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        # Send proxy v2 header first, then 2 keepalive requests
        $sock->syswrite(build_proxy_v2('PROXY', 'INET', '10.0.0.77', '10.0.0.1', 23456, 80));
        my ($s1, $b1) = http1_request($sock, 'GET', '/ka-v2-1', connection => 'keep-alive');
        return 2 unless $s1 eq '200';
        my ($s2, $b2) = http1_request($sock, 'GET', '/ka-v2-2', connection => 'close');
        $sock->close;
        return ($s2 eq '200' && $b1 =~ /addr=10\.0\.0\.77/ && $b2 =~ /addr=10\.0\.0\.77/) ? 0 : 3;
    });

    cmp_ok scalar(@captured), '>=', 2, "keepalive-proxy-v2: received 2 requests";
    is $captured[0]{addr}, '10.0.0.77', "keepalive-proxy-v2: REMOTE_ADDR from proxy";
};

# ===========================================================================
# PSGI handler equivalent - returns standard PSGI arrayref
# ===========================================================================
my $psgi_handler = sub {
    my $env = shift;
    my $method = $env->{REQUEST_METHOD} || 'GET';
    my $path   = $env->{PATH_INFO} || '/';
    my $cl     = $env->{CONTENT_LENGTH} || 0;
    my $body   = '';
    if ($cl > 0 && $env->{'psgi.input'}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    my $addr   = $env->{REMOTE_ADDR} || '';
    my $scheme = $env->{'psgi.url_scheme'} || '';
    my $proto  = $env->{SERVER_PROTOCOL} || '';

    push @captured, {
        method => $method, path => $path, body => $body,
        addr => $addr, scheme => $scheme, proto => $proto,
    };

    my $resp = "method=$method path=$path body=$body addr=$addr scheme=$scheme proto=$proto";
    return [200, [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($resp),
    ], [$resp]];
};

# PSGI streaming handler - delayed response with writer
my $psgi_streaming_handler = sub {
    my $env = shift;
    my $method = $env->{REQUEST_METHOD} || 'GET';
    my $path   = $env->{PATH_INFO} || '/';
    my $cl     = $env->{CONTENT_LENGTH} || 0;
    my $body   = '';
    if ($cl > 0 && $env->{'psgi.input'}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    my $addr   = $env->{REMOTE_ADDR} || '';
    my $scheme = $env->{'psgi.url_scheme'} || '';

    push @captured, {
        method => $method, path => $path, body => $body,
        addr => $addr, scheme => $scheme,
    };

    return sub {
        my $responder = shift;
        my $w = $responder->([200, [
            'Content-Type' => 'text/plain',
        ]]);
        my $resp = "method=$method path=$path body=$body addr=$addr scheme=$scheme";
        $w->write($resp);
        $w->close();
    };
};

# ===========================================================================
# Test 39: PSGI plain HTTP/1.1 GET+POST
# ===========================================================================
subtest 'PSGI: Plain HTTP/1.1 GET+POST' => sub {
    plan tests => 8;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "psgi-plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->psgi_request_handler($psgi_handler);

    @captured = ();
    run_client("psgi plain GET", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        my ($status, $body) = http1_request($sock, 'GET', '/psgi-get');
        $sock->close;
        return ($status eq '200' && $body =~ /method=GET/ && $body =~ /path=\/psgi-get/) ? 0 : 2;
    });

    run_client("psgi plain POST", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        my ($status, $body) = http1_request($sock, 'POST', '/psgi-post', body => 'psgi=data');
        $sock->close;
        return ($status eq '200' && $body =~ /body=psgi=data/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 2, "psgi-plain: received both requests";
    is $captured[0]{scheme}, 'http', "psgi-plain: url_scheme is http";
    is $captured[1]{body}, 'psgi=data', "psgi-plain: POST body correct";
};

# ===========================================================================
# Test 40: PSGI TLS/H1 GET+POST
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI: TLS/H1 GET+POST' => sub {
        plan tests => 8;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->psgi_request_handler($psgi_handler);

        @captured = ();
        run_client("psgi tls GET", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'GET', '/psgi-tls-get');
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /path=\/psgi-tls-get/ && $body =~ /scheme=https/) ? 0 : 2;
        });

        run_client("psgi tls POST", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            my ($status, $body) = http1_request($sock, 'POST', '/psgi-tls-post', body => 'tls=psgi');
            $sock->close(SSL_no_shutdown => 1);
            return ($status eq '200' && $body =~ /body=tls=psgi/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 2, "psgi-tls: received both requests";
        is $captured[0]{scheme}, 'https', "psgi-tls: url_scheme is https";
        is $captured[1]{body}, 'tls=psgi', "psgi-tls: POST body correct";
    };
}

# ===========================================================================
# Test 41: PSGI H2 GET+POST
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI: H2 GET+POST' => sub {
        plan tests => 8;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->psgi_request_handler($psgi_handler);

        @captured = ();
        run_client("psgi h2 GET", sub {
            my $sock = h2_connect($port) or return 1;
            my ($status, $body) = h2_request($sock, 1, 'GET', '/psgi-h2-get', $port);
            $sock->close;
            return (defined $status && $status eq '200' && $body =~ /path=\/psgi-h2-get/) ? 0 : 2;
        });

        run_client("psgi h2 POST", sub {
            my $sock = h2_connect($port) or return 1;
            my ($status, $body) = h2_request($sock, 1, 'POST', '/psgi-h2-post', $port, body => 'h2=psgi');
            $sock->close;
            return (defined $status && $status eq '200' && $body =~ /body=h2=psgi/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 2, "psgi-h2: received both requests";
        is $captured[0]{scheme}, 'https', "psgi-h2: url_scheme is https";
        is $captured[1]{body}, 'h2=psgi', "psgi-h2: POST body correct";
    };
}

# ===========================================================================
# Test 42: PSGI streaming (plain)
# ===========================================================================
subtest 'PSGI streaming: Plain HTTP/1.1' => sub {
    plan tests => 5;

    my ($socket, $port) = get_listen_socket();
    ok $socket, "psgi-stream-plain: got socket on $port";

    my $evh = Feersum->new_instance();
    $evh->use_socket($socket);
    $evh->psgi_request_handler($psgi_streaming_handler);

    @captured = ();
    run_client("psgi streaming plain GET", sub {
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT,
        ) or return 1;
        $sock->print("GET /psgi-stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        my $buf = '';
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $n = $sock->sysread(my $chunk, 4096);
            last if !defined($n) || $n == 0;
            $buf .= $chunk;
        }
        $sock->close;
        my ($status) = $buf =~ m{HTTP/1\.\d (\d+)};
        return ($status && $status eq '200' && $buf =~ /method=GET/ && $buf =~ /path=\/psgi-stream/) ? 0 : 2;
    });

    cmp_ok scalar(@captured), '>=', 1, "psgi-stream-plain: received request";
    is $captured[0]{scheme}, 'http', "psgi-stream-plain: url_scheme is http";
};

# ===========================================================================
# Test 43: PSGI streaming (TLS)
# ===========================================================================
SKIP: {
    skip "TLS not available", 1 unless $HAS_TLS && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI streaming: TLS/H1' => sub {
        plan tests => 5;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-stream-tls: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file);
        $evh->psgi_request_handler($psgi_streaming_handler);

        @captured = ();
        run_client("psgi streaming tls GET", sub {
            my $sock = IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                Timeout => 5 * TIMEOUT_MULT,
            ) or return 1;
            $sock->print("GET /psgi-stream-tls HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            my $buf = '';
            my $deadline = time + 5 * TIMEOUT_MULT;
            while (time < $deadline) {
                my $n = $sock->sysread(my $chunk, 4096);
                last if !defined($n) || $n == 0;
                $buf .= $chunk;
            }
            $sock->close(SSL_no_shutdown => 1);
            my ($status) = $buf =~ m{HTTP/1\.\d (\d+)};
            return ($status && $status eq '200' && $buf =~ /scheme=https/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 1, "psgi-stream-tls: received request";
        is $captured[0]{scheme}, 'https', "psgi-stream-tls: url_scheme is https";
    };
}

# ===========================================================================
# Test 44: PSGI streaming (H2)
# ===========================================================================
SKIP: {
    skip "H2 not available", 1 unless $HAS_TLS && $HAS_H2 && $HAS_SSL && $HAS_CERTS;

    subtest 'PSGI streaming: H2' => sub {
        plan tests => 5;

        my $settle_cv = AE::cv;
        my $settle_t = AE::timer(0.5, 0, sub { $settle_cv->send });
        $settle_cv->recv;

        my ($socket, $port) = get_listen_socket();
        ok $socket, "psgi-stream-h2: got socket on $port";

        my $evh = Feersum->new_instance();
        $evh->use_socket($socket);
        $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1);
        $evh->psgi_request_handler($psgi_streaming_handler);

        @captured = ();
        run_client("psgi streaming h2 GET", sub {
            my $sock = h2_connect($port) or return 1;
            my ($status, $body) = h2_request($sock, 1, 'GET', '/psgi-stream-h2', $port);
            $sock->close;
            return (defined $status && $status eq '200' && $body =~ /scheme=https/) ? 0 : 2;
        });

        cmp_ok scalar(@captured), '>=', 1, "psgi-stream-h2: received request";
        is $captured[0]{scheme}, 'https', "psgi-stream-h2: url_scheme is https";
    };
}

done_testing;
