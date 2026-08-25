#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
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

use H2Utils;

# Send Extended CONNECT HEADERS + optional initial data, all in one write
sub h2_send_extended_connect {
    my ($sock, $stream_id, $path, $port, $initial_data) = @_;

    my $headers_block = hpack_encode_headers(
        [':method',    'CONNECT'],
        [':protocol',  'websocket'],
        [':path',      $path],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );

    my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, $stream_id, $headers_block);
    if (defined $initial_data && length($initial_data) > 0) {
        $out .= h2_frame(H2_DATA, 0, $stream_id, $initial_data);
    }

    $sock->syswrite($out);
}

# ---------------------------------------------------------------------------
# Handler setup
# ---------------------------------------------------------------------------
my @tunnel_requests;
$evh->psgi_request_handler(sub {
    my $env = shift;

    # Detect upgrade requests using standard HTTP headers - works for
    # both HTTP/1.1 Upgrade and H2 Extended CONNECT transparently.
    if (($env->{HTTP_CONNECTION} || '') =~ /\bupgrade\b/i
        && $env->{HTTP_UPGRADE})
    {
        push @tunnel_requests, {
            method     => $env->{REQUEST_METHOD},
            upgrade    => $env->{HTTP_UPGRADE},
            connection => $env->{HTTP_CONNECTION},
            path       => $env->{PATH_INFO} || '',
        };

        my $path = $env->{PATH_INFO} || '';

        if ($path eq '/reject') {
            return [403, ['Content-Type' => 'text/plain'], ['Forbidden']];
        }

        if ($path eq '/server-close') {
            # Accept tunnel then close from server side after brief delay
            return sub {
                my $responder = shift;
                my $writer = $responder->([200, ['X-Tunnel' => 'accepted']]);
                my $io = $env->{'psgix.io'};
                unless ($io && ref($io)) {
                    $writer->close();
                    return;
                }
                my $t; $t = AE::timer(0.2, 0, sub {
                    undef $t;
                    close($io);
                });
            };
        }

        # Accept the tunnel via delayed response
        return sub {
            my $responder = shift;
            my $writer = $responder->([200, ['X-Tunnel' => 'accepted']]);

            # Get tunnel socket via psgix.io
            my $io = $env->{'psgix.io'};
            unless ($io && ref($io)) {
                $writer->close();
                return;
            }

            # Set up AnyEvent echo handler: prepend "echo:" only once
            my $first = 1;
            my $handle; $handle = AnyEvent::Handle->new(
                fh       => $io,
                on_error => sub { $_[0]->destroy; undef $handle; },
                on_eof   => sub { $handle->destroy if $handle; undef $handle; },
            );
            $handle->on_read(sub {
                my $data = $handle->{rbuf};
                $handle->{rbuf} = '';
                if ($first) {
                    $handle->push_write("echo:$data");
                    $first = 0;
                } else {
                    $handle->push_write($data);
                }
            });
        };
    }

    # Probe psgix.io on a regular (non-tunnel) H2 stream: it must be undef,
    # not a truthy fd integer (regression guard for the magic-get failure
    # branch that used to leave the fd-int backing value in place).
    if (($env->{PATH_INFO} || '') eq '/psgix-io-check') {
        my $io = $env->{'psgix.io'};
        my $body = defined($io) ? "defined:$io" : "undef";
        return [200, ['Content-Type' => 'text/plain',
            'Content-Length' => length($body)], [$body]];
    }

    # Non-tunnel: normal response
    my $body = "hello";
    return [200, ['Content-Type' => 'text/plain', 'Content-Length' => length($body)], [$body]];
});

# ---------------------------------------------------------------------------
# Test 1: SETTINGS includes ENABLE_CONNECT_PROTOCOL=1
# ---------------------------------------------------------------------------
subtest 'SETTINGS includes ENABLE_CONNECT_PROTOCOL' => sub {
    plan tests => 2;

    h2_fork_test("ENABLE_CONNECT_PROTOCOL", $port, sub {
        my ($port) = @_;

        my ($sock, $settings_payload) = h2_connect($port);
        unless ($sock && $settings_payload) {
            exit(1);
        }

        my $found = 0;
        my $pos = 0;
        while ($pos + 6 <= length($settings_payload)) {
            my ($id, $val) = unpack('nN', substr($settings_payload, $pos, 6));
            $pos += 6;
            if ($id == SETTINGS_ENABLE_CONNECT_PROTOCOL && $val == 1) {
                $found = 1;
                last;
            }
        }

        $sock->close();
        exit($found ? 0 : 2);
    }, timeout_mult => TIMEOUT_MULT);
};

# ---------------------------------------------------------------------------
# Test 2: Extended CONNECT env + accept (200) + bidirectional echo
# ---------------------------------------------------------------------------
subtest 'Extended CONNECT: env + bidirectional echo' => sub {
    plan tests => 7;

    @tunnel_requests = ();

    h2_fork_test("echo test", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        # Send Extended CONNECT + initial data in one write
        h2_send_extended_connect($sock, 1, '/tunnel', $port, "hello-tunnel");

        # Read response HEADERS
        my $got_200 = 0;
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $f = h2_read_frame($sock, $deadline - time);
            last unless $f;
            if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                my $status = hpack_decode_status($f->{payload});
                $got_200 = 1 if defined $status && $status eq '200';
                last;
            }
        }
        exit(2) unless $got_200;

        # Read echoed data
        my $echoed = '';
        $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            my $f = h2_read_frame($sock, $deadline - time);
            last unless $f;
            if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                $echoed .= $f->{payload};
                last if $echoed =~ /echo:/;
            }
        }

        # Close our side
        $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        $sock->close();

        exit($echoed eq "echo:hello-tunnel" ? 0 : 3);
    }, timeout_mult => TIMEOUT_MULT, timeout => 15);

    cmp_ok scalar(@tunnel_requests), '>=', 1, "handler saw tunnel request";
    if (@tunnel_requests) {
        is $tunnel_requests[0]{method},     'GET',       "REQUEST_METHOD is GET (translated)";
        is $tunnel_requests[0]{upgrade},    'websocket', "HTTP_UPGRADE is websocket";
        is $tunnel_requests[0]{connection}, 'Upgrade',   "HTTP_CONNECTION is Upgrade";
        is $tunnel_requests[0]{path},       '/tunnel',   "PATH_INFO is /tunnel";
    }
};

# ---------------------------------------------------------------------------
# Test 3: Reject (403) - no socketpair created
# ---------------------------------------------------------------------------
subtest 'Extended CONNECT reject (403)' => sub {
    plan tests => 2;

    @tunnel_requests = ();

    h2_fork_test("reject test", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        h2_send_extended_connect($sock, 1, '/reject', $port);

        my $got_403 = 0;
        my $f = h2_read_until($sock, H2_HEADERS, 1, 5);
        if ($f) {
            my $status = hpack_decode_status($f->{payload});
            $got_403 = 1 if defined $status && $status eq '403';
        }

        $sock->close();
        exit($got_403 ? 0 : 2);
    }, timeout_mult => TIMEOUT_MULT);
};

# ---------------------------------------------------------------------------
# Test 4: Client close via RST_STREAM
# ---------------------------------------------------------------------------
subtest 'Client RST_STREAM closes tunnel' => sub {
    plan tests => 2;

    @tunnel_requests = ();

    h2_fork_test("RST_STREAM test", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        h2_send_extended_connect($sock, 1, '/tunnel', $port);

        # Wait for 200
        my $f = h2_read_until($sock, H2_HEADERS, 1, 5);
        exit(2) unless $f;
        my $status = hpack_decode_status($f->{payload});
        exit(2) unless defined $status && $status eq '200';

        # RST_STREAM (CANCEL)
        $sock->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 0x08)));
        select(undef, undef, undef, 0.5 * TIMEOUT_MULT);
        $sock->close();
        exit(0);
    }, timeout_mult => TIMEOUT_MULT);
};

# ---------------------------------------------------------------------------
# Test 5: Concurrent tunnels on one connection
# ---------------------------------------------------------------------------
my $nghttp_bin = `which nghttp 2>/dev/null`;
chomp $nghttp_bin;

subtest 'Concurrent tunnels on one H2 connection' => sub {
    plan tests => 2;

    @tunnel_requests = ();

    h2_fork_test("concurrent tunnels", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        # Open 2 concurrent tunnel streams (stream IDs 1, 3) with initial
        # data bundled in each HEADERS+DATA pair (one syswrite per stream).
        h2_send_extended_connect($sock, 1, '/tunnel', $port, "msg-1");
        h2_send_extended_connect($sock, 3, '/tunnel', $port, "msg-3");

        # Collect 200 HEADERS and echoed DATA for both streams
        my %got_200;
        my %echoed;
        my $deadline = time + 8 * TIMEOUT_MULT;
        while ((keys(%got_200) < 2 || keys(%echoed) < 2) && time < $deadline) {
            my $f = h2_read_frame($sock, $deadline - time);
            last unless $f;
            if ($f->{type} == H2_HEADERS && ($f->{stream_id} % 2 == 1)) {
                my $status = hpack_decode_status($f->{payload});
                $got_200{$f->{stream_id}} = 1 if defined $status && $status eq '200';
            }
            if ($f->{type} == H2_DATA && ($f->{stream_id} % 2 == 1) && length($f->{payload}) > 0) {
                $echoed{$f->{stream_id}} //= '';
                $echoed{$f->{stream_id}} .= $f->{payload};
            }
            # Send WINDOW_UPDATE for DATA frames
            if ($f->{type} == H2_DATA && $f->{length} > 0) {
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $f->{stream_id}, pack('N', $f->{length})));
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $f->{length})));
            }
        }

        # Close both streams
        $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
        $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 3, ''));
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        $sock->close();

        exit(2) unless keys(%got_200) == 2;

        # Verify each stream got its own echo
        my $ok = ($echoed{1} // '') eq 'echo:msg-1'
              && ($echoed{3} // '') eq 'echo:msg-3';
        exit($ok ? 0 : 3);
    }, timeout_mult => TIMEOUT_MULT, timeout => 15);
};

# ---------------------------------------------------------------------------
# Test 6: Server-initiated tunnel close
# ---------------------------------------------------------------------------
subtest 'Server-initiated tunnel close' => sub {
    plan tests => 2;

    @tunnel_requests = ();

    h2_fork_test("server-close test", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        h2_send_extended_connect($sock, 1, '/server-close', $port);

        # Wait for 200
        my $f = h2_read_until($sock, H2_HEADERS, 1, 5);
        exit(2) unless $f;
        my $status = hpack_decode_status($f->{payload});
        exit(2) unless defined $status && $status eq '200';

        # Server will close its end after ~0.2s.
        # We should see either END_STREAM on DATA or RST_STREAM.
        my $saw_end = 0;
        my $deadline = time + 5 * TIMEOUT_MULT;
        while (time < $deadline) {
            $f = h2_read_frame($sock, $deadline - time);
            last unless $f;
            if ($f->{stream_id} == 1) {
                if ($f->{type} == H2_DATA && ($f->{flags} & FLAG_END_STREAM)) {
                    $saw_end = 1;
                    last;
                }
                if ($f->{type} == H2_RST_STREAM) {
                    $saw_end = 1;
                    last;
                }
            }
        }

        $sock->close();
        exit($saw_end ? 0 : 3);
    }, timeout_mult => TIMEOUT_MULT);
};

# ---------------------------------------------------------------------------
# Test 7: Large data through tunnel
# ---------------------------------------------------------------------------
subtest 'Large data through tunnel' => sub {
    plan tests => 2;

    @tunnel_requests = ();

    h2_fork_test("large data test", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        # Send a larger payload through the tunnel.
        # Use 8KB (well within max frame size and flow control window).
        my $payload = 'B' x 8192;
        h2_send_extended_connect($sock, 1, '/tunnel', $port, $payload);

        # Read response HEADERS (200)
        my $got_200 = 0;
        my $echoed = '';
        my $expected = "echo:" . $payload;
        my $deadline = time + 8 * TIMEOUT_MULT;
        while (length($echoed) < length($expected) && time < $deadline) {
            my $f = h2_read_frame($sock, $deadline - time);
            last unless $f;
            if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                my $status = hpack_decode_status($f->{payload});
                $got_200 = 1 if defined $status && $status eq '200';
            }
            if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                $echoed .= $f->{payload};
            }
            if ($f->{type} == H2_GOAWAY || $f->{type} == H2_RST_STREAM) {
                last;
            }
            # Send WINDOW_UPDATE for DATA frames
            if ($f->{type} == H2_DATA && length($f->{payload}) > 0) {
                my $wulen = length($f->{payload});
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $f->{stream_id}, pack('N', $wulen)));
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $wulen)));
            }
        }

        # Close stream
        $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        $sock->close();

        exit(2) unless $got_200;
        exit($echoed eq $expected ? 0 : 3);
    }, timeout_mult => TIMEOUT_MULT, timeout => 15);
};


# ---------------------------------------------------------------------------
# Test 8: Regular H2 GET still works (regression)
# ---------------------------------------------------------------------------
SKIP: {
    skip "nghttp not found in PATH", 1 unless $nghttp_bin && -x $nghttp_bin;

    subtest 'Regular H2 GET still works' => sub {
        plan tests => 2;

        h2_fork_test("regression GET", $port, sub {
            my ($port) = @_;
            my $url = "https://127.0.0.1:$port/hello";
            my $output = `$nghttp_bin --no-verify $url 2>&1`;
            exit($output =~ /hello/ ? 0 : 1);
        }, timeout_mult => TIMEOUT_MULT, timeout => 15, delay => 0.5);
    };
}

# ---------------------------------------------------------------------------
# Test 9: psgix.io is undef on a regular (non-tunnel) H2 stream
# ---------------------------------------------------------------------------
SKIP: {
    skip "nghttp not found in PATH", 1 unless $nghttp_bin && -x $nghttp_bin;

    subtest 'psgix.io undef on regular H2 stream' => sub {
        plan tests => 2;

        h2_fork_test("psgix.io check", $port, sub {
            my ($port) = @_;
            my $url = "https://127.0.0.1:$port/psgix-io-check";
            my $output = `$nghttp_bin --no-verify $url 2>/dev/null`;
            # Body must be exactly "undef" - a "defined:<fd>" body means the
            # magic-get leaked the raw fd integer as a truthy handle.
            exit($output =~ /\bundef\b/ && $output !~ /defined:/ ? 0 : 1);
        }, timeout_mult => TIMEOUT_MULT, timeout => 15, delay => 0.5);
    };
}

# ========================================================================
# Test 9: Client GOAWAY during active tunnel - stream cleans up gracefully
# ========================================================================
h2_fork_test("GOAWAY during active tunnel", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port);
    exit(1) unless $sock;

    # Open Extended CONNECT tunnel
    h2_send_extended_connect($sock, 1, '/goaway-test', $port, "hello");

    # Wait for 200 HEADERS
    my $deadline = time + 5 * TIMEOUT_MULT;
    my $got_200 = 0;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $got_200 = 1;
            last;
        }
    }
    exit(2) unless $got_200;

    # Read echo data
    my $echo = '';
    $deadline = time + 3 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $echo .= $f->{payload};
            last if length($echo) >= 5;
        }
    }

    # Send GOAWAY while tunnel stream 1 is still active
    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 1, 0)));
    select(undef, undef, undef, 0.2);
    $sock->close();
    exit($echo =~ /hello/ ? 0 : 3);
}, timeout_mult => TIMEOUT_MULT);

# ========================================================================
# Test 10: Extended CONNECT via native request_handler + $req->io()
# ========================================================================
subtest 'Extended CONNECT via native io()' => sub {
    plan tests => 2;

    # Switch to native request_handler for this test
    $evh->request_handler(sub {
        my $req = shift;

        # Get tunnel IO handle via native interface
        my $io = $req->io();
        unless ($io && ref($io)) {
            return;
        }

        # Echo with "native:" prefix
        my $handle; $handle = AnyEvent::Handle->new(
            fh       => $io,
            on_error => sub { $_[0]->destroy; undef $handle; },
            on_eof   => sub { $handle->destroy if $handle; undef $handle; },
        );
        $handle->on_read(sub {
            my $data = $handle->{rbuf};
            $handle->{rbuf} = '';
            $handle->push_write("native:$data");
        });
    });

    h2_fork_test("native io() tunnel", $port, sub {
        my ($port) = @_;

        my ($sock) = h2_connect($port);
        exit(1) unless $sock;

        h2_send_extended_connect($sock, 1, '/native-test', $port, "test-data");

        my $got_200 = 0;
        my $echoed = '';
        my $expected = "native:test-data";
        my $deadline = time + 8 * TIMEOUT_MULT;
        while (length($echoed) < length($expected) && time < $deadline) {
            my $f = h2_read_frame($sock, $deadline - time);
            last unless $f;
            if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
                my $status = hpack_decode_status($f->{payload});
                $got_200 = 1 if defined $status && $status eq '200';
            }
            if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
                $echoed .= $f->{payload};
            }
            if ($f->{type} == H2_DATA && length($f->{payload}) > 0) {
                my $wulen = length($f->{payload});
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $f->{stream_id}, pack('N', $wulen)));
                $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $wulen)));
            }
        }

        $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        $sock->close();

        exit(2) unless $got_200;
        exit($echoed eq $expected ? 0 : 3);
    }, timeout_mult => TIMEOUT_MULT, timeout => 15);
};

done_testing;
