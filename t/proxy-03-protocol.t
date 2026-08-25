#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN { plan tests => 74 }

use Feersum;
use AnyEvent;
use AnyEvent::Handle;

# Test get/set singleton methods
is(Feersum->get_proxy_protocol, 0, 'default is off');
Feersum->set_proxy_protocol(1);
is(Feersum->get_proxy_protocol, 1, 'enabled via class method');

my $f = Feersum->new;
is($f->get_proxy_protocol, 1, 'instance sees global setting');
$f->set_proxy_protocol(0);
is(Feersum->get_proxy_protocol, 0, 'instance method affects global');

# Helper to send PROXY header + HTTP request via AnyEvent
# Takes port as first argument for flexibility
sub proxy_client_to_port {
    my ($target_port, $proxy_header, $http_method, $uri, $cb) = @_;

    my $cv = AE::cv;
    $cv->begin;

    my $response_buf = '';
    my %hdrs;
    my $h;
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $target_port],
        on_connect => sub {
            my $handle = shift;
            # Send PROXY header first, then HTTP request
            $handle->push_write($proxy_header) if length($proxy_header);
            $handle->push_write("$http_method $uri HTTP/1.1\r\n");
            $handle->push_write("Host: localhost\r\n");
            $handle->push_write("Connection: close\r\n");
            $handle->push_write("\r\n");
        },
        on_error => sub {
            my ($handle, $fatal, $msg) = @_;
            %hdrs = (Status => 599, Reason => $msg);
            $handle->destroy;
            $cv->end;
        },
        timeout => 3,
    );

    # Read response
    $h->push_read(regex => qr/\r\n\r\n/, sub {
        my ($handle, $header_data) = @_;
        my @lines = split(/\r\n/, $header_data);
        my $status_line = shift @lines;
        if ($status_line =~ m{HTTP/(1\.\d) (\d{3})\s*(.*)}) {
            $hdrs{HTTPVersion} = $1;
            $hdrs{Status} = $2;
            $hdrs{Reason} = $3;
        }
        for my $line (@lines) {
            my ($k, $v) = split(/:\s*/, $line, 2);
            $hdrs{lc($k)} = $v if defined $k;
        }

        # Read body if content-length
        if (defined $hdrs{'content-length'} && $hdrs{'content-length'} > 0) {
            $handle->push_read(chunk => $hdrs{'content-length'}, sub {
                $response_buf = $_[1];
                $handle->destroy;
                $cv->end;
            });
        } else {
            $handle->on_eof(sub {
                $handle->destroy;
                $cv->end;
            });
            $handle->on_read(sub {
                $response_buf .= $_[0]->{rbuf};
                $_[0]->{rbuf} = '';
            });
        }
    });

    $cv->recv;
    $cb->($response_buf, \%hdrs);
}

# Keep all sockets alive to prevent port reuse issues
my @keep_alive_sockets;

# ========================================
# Test group 1: PROXY v1 and v2 parsing
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_keepalive(0);

    my ($socket, $port) = get_listen_socket();
    push @keep_alive_sockets, $socket;  # Prevent GC
    my $evh = Feersum->new;
    $evh->use_socket($socket);

    my %captured_env;
    $evh->psgi_request_handler(sub {
        my $env = shift;
        %captured_env = (
            REMOTE_ADDR => $env->{REMOTE_ADDR},
            REMOTE_PORT => $env->{REMOTE_PORT},
        );
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    # Test 1: PROXY v1 TCP4
    {
        my $proxy_header = build_proxy_v1('TCP4', '203.0.113.50', '192.0.2.1', 54321, 80);
        proxy_client_to_port($port, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v1 TCP4: response OK');
        });
        is($captured_env{REMOTE_ADDR}, '203.0.113.50', 'PROXY v1 TCP4: REMOTE_ADDR updated');
        is($captured_env{REMOTE_PORT}, '54321', 'PROXY v1 TCP4: REMOTE_PORT updated');
    }

    # Test 2: PROXY v1 TCP6
    {
        my $proxy_header = build_proxy_v1('TCP6', '2001:db8::1', '2001:db8::2', 54322, 80);
        proxy_client_to_port($port, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v1 TCP6: response OK');
        });
        is($captured_env{REMOTE_ADDR}, '2001:db8::1', 'PROXY v1 TCP6: REMOTE_ADDR updated');
        is($captured_env{REMOTE_PORT}, '54322', 'PROXY v1 TCP6: REMOTE_PORT updated');
    }

    # Test 3: PROXY v1 UNKNOWN (health check - keeps original address)
    {
        my $proxy_header = build_proxy_v1('UNKNOWN');
        proxy_client_to_port($port, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v1 UNKNOWN: response OK');
        });
        is($captured_env{REMOTE_ADDR}, '127.0.0.1', 'PROXY v1 UNKNOWN: keeps original address');
    }

    # Test 4: PROXY v2 PROXY IPv4
    {
        my $proxy_header = build_proxy_v2('PROXY', 'INET', '198.51.100.1', '198.51.100.2', 12345, 80);
        proxy_client_to_port($port, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v2 INET: response OK');
        });
        is($captured_env{REMOTE_ADDR}, '198.51.100.1', 'PROXY v2 INET: REMOTE_ADDR updated');
        is($captured_env{REMOTE_PORT}, '12345', 'PROXY v2 INET: REMOTE_PORT updated');
    }

    # Test 5: PROXY v2 PROXY IPv6
    SKIP: {
        eval { Socket::inet_pton(Socket::AF_INET6(), '::1') };
        skip "IPv6 not supported on this system", 3 if $@;

        my $proxy_header = build_proxy_v2('PROXY', 'INET6', '2001:db8:85a3::8a2e:370:7334', '2001:db8::1', 23456, 443);
        proxy_client_to_port($port, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v2 INET6: response OK');
        });
        is($captured_env{REMOTE_ADDR}, '2001:db8:85a3::8a2e:370:7334', 'PROXY v2 INET6: REMOTE_ADDR updated');
        is($captured_env{REMOTE_PORT}, '23456', 'PROXY v2 INET6: REMOTE_PORT updated');
    }

    # Test 6: PROXY v2 LOCAL (health check - keeps original address)
    {
        my $proxy_header = build_proxy_v2('LOCAL', 'UNSPEC');
        proxy_client_to_port($port, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v2 LOCAL: response OK');
        });
        is($captured_env{REMOTE_ADDR}, '127.0.0.1', 'PROXY v2 LOCAL: keeps original address');
    }

    # Test 7: Invalid PROXY v1 (malformed)
    {
        my $bad_header = "PROXY INVALID garbage\r\n";
        proxy_client_to_port($port, $bad_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/, 'Invalid PROXY v1: returns 4xx error');
        });
    }

    # Test 8: Invalid PROXY v2 (bad signature)
    {
        my $bad_header = "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x00\x00\x00\x00\x00";
        $bad_header .= "\x21\x11\x00\x0C";
        $bad_header .= "\x00" x 12;
        proxy_client_to_port($port, $bad_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/, 'Invalid PROXY v2 signature: returns 4xx error');
        });
    }

    # Test 9: No PROXY header when expected (starts with 'G' for GET)
    {
        proxy_client_to_port($port, '', 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/, 'Missing PROXY header: returns 4xx error');
        });
    }
}

# ========================================
# Test group 2: proxy_protocol disabled
# ========================================
{
    Feersum->set_proxy_protocol(0);

    my ($socket2, $port2) = get_listen_socket();
    push @keep_alive_sockets, $socket2;
    my $evh2 = Feersum->new;
    $evh2->use_socket($socket2);

    my %env2;
    $evh2->psgi_request_handler(sub {
        my $env = shift;
        %env2 = (REMOTE_ADDR => $env->{REMOTE_ADDR});
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    my $cv = AE::cv;
    $cv->begin;
    my $h = simple_client GET => '/', port => $port2,
        sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'proxy_protocol disabled: HTTP works');
            is($env2{REMOTE_ADDR}, '127.0.0.1', 'proxy_protocol disabled: real REMOTE_ADDR');
            $cv->end;
        };
    $cv->recv;
}

# ========================================
# Test group 3: Keep-alive with PROXY protocol
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_keepalive(1);

    my ($ka_socket, $ka_port) = get_listen_socket();
    push @keep_alive_sockets, $ka_socket;
    my $ka_evh = Feersum->new;
    $ka_evh->use_socket($ka_socket);

    my @ka_addrs;
    $ka_evh->psgi_request_handler(sub {
        my $env = shift;
        push @ka_addrs, $env->{REMOTE_ADDR};
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    my $proxy_header = build_proxy_v1('TCP4', '10.0.0.1', '10.0.0.2', 11111, 80);

    my $cv = AE::cv;
    $cv->begin;

    my $response_count = 0;
    my $h;
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $ka_port],
        on_connect => sub {
            my $handle = shift;
            $handle->push_write($proxy_header);
            $handle->push_write("GET /first HTTP/1.1\r\nHost: localhost\r\n\r\n");
        },
        on_error => sub {
            my ($handle, $fatal, $msg) = @_;
            $handle->destroy;
            $cv->end;
        },
        timeout => 3,
    );

    my $read_response;
    $read_response = sub {
        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $response_count++;

            my ($cl) = $header_data =~ /Content-Length:\s*(\d+)/i;
            $cl ||= 2;

            $handle->push_read(chunk => $cl, sub {
                if ($response_count == 1) {
                    $handle->push_write("GET /second HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
                    $read_response->();
                } else {
                    $handle->destroy;
                    $cv->end;
                }
            });
        });
    };
    $read_response->();

    $cv->recv;

    is($ka_addrs[0], '10.0.0.1', 'Keep-alive first request: correct REMOTE_ADDR');
    is($ka_addrs[1], '10.0.0.1', 'Keep-alive second request: REMOTE_ADDR preserved');

    Feersum->set_keepalive(0);
}

# ========================================
# Test group 4: Server recovery after error
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_keepalive(0);

    my ($socket4, $port4) = get_listen_socket();
    push @keep_alive_sockets, $socket4;
    my $evh4 = Feersum->new;
    $evh4->use_socket($socket4);

    my %captured_env4;
    $evh4->psgi_request_handler(sub {
        my $env = shift;
        %captured_env4 = (REMOTE_ADDR => $env->{REMOTE_ADDR});
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    # Send invalid request
    proxy_client_to_port($port4, "INVALID_PROXY\r\n", 'GET', '/', sub {
        my ($body, $hdr) = @_;
        like($hdr->{Status}, qr/^4\d\d$/, 'Invalid PROXY rejected');
    });

    # Send valid request
    my $proxy_header = build_proxy_v1('TCP4', '192.168.1.1', '192.168.1.2', 33333, 80);
    proxy_client_to_port($port4, $proxy_header, 'GET', '/', sub {
        my ($body, $hdr) = @_;
        is($hdr->{Status}, 200, 'Server still works after invalid PROXY');
    });
    is($captured_env4{REMOTE_ADDR}, '192.168.1.1', 'Valid request has correct REMOTE_ADDR');
}

# ========================================
# Test group 5: Combined with reverse_proxy
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_reverse_proxy(1);

    my ($socket5, $port5) = get_listen_socket();
    push @keep_alive_sockets, $socket5;
    my $evh5 = Feersum->new;
    $evh5->use_socket($socket5);

    my %env5;
    $evh5->psgi_request_handler(sub {
        my $env = shift;
        %env5 = (
            REMOTE_ADDR => $env->{REMOTE_ADDR},
            'psgi.url_scheme' => $env->{'psgi.url_scheme'},
        );
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    my $cv = AE::cv;
    $cv->begin;

    my $proxy_header = build_proxy_v1('TCP4', '10.10.10.10', '10.10.10.1', 44444, 80);

    my $h;
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port5],
        on_connect => sub {
            my $handle = shift;
            $handle->push_write($proxy_header);
            $handle->push_write("GET / HTTP/1.1\r\n");
            $handle->push_write("Host: localhost\r\n");
            $handle->push_write("X-Forwarded-For: 203.0.113.99\r\n");
            $handle->push_write("X-Forwarded-Proto: https\r\n");
            $handle->push_write("Connection: close\r\n");
            $handle->push_write("\r\n");
        },
        on_error => sub { $_[0]->destroy; $cv->end; },
        timeout => 3,
    );

    $h->push_read(regex => qr/\r\n\r\n/, sub {
        my ($handle, $header_data) = @_;
        my ($status) = $header_data =~ m{HTTP/1\.\d (\d{3})};
        is($status, 200, 'proxy_protocol + reverse_proxy: response OK');
        $handle->on_eof(sub { $handle->destroy; $cv->end; });
        $handle->on_read(sub { });
    });

    $cv->recv;

    is($env5{REMOTE_ADDR}, '203.0.113.99', 'reverse_proxy: X-Forwarded-For takes precedence');
    is($env5{'psgi.url_scheme'}, 'https', 'reverse_proxy: X-Forwarded-Proto applied');

    Feersum->set_reverse_proxy(0);
}

# ========================================
# Test group 6: Native interface
# ========================================
{
    Feersum->set_proxy_protocol(1);

    my ($socket6, $port6) = get_listen_socket();
    push @keep_alive_sockets, $socket6;
    my $evh6 = Feersum->new;
    $evh6->use_socket($socket6);

    my %native_env;
    $evh6->request_handler(sub {
        my $req = shift;
        %native_env = (
            remote_address => $req->remote_address,
            remote_port => $req->remote_port,
        );
        $req->send_response(200, ['Content-Type' => 'text/plain'], \'ok');
    });

    my $cv = AE::cv;
    $cv->begin;

    my $proxy_header = build_proxy_v1('TCP4', '172.16.0.1', '172.16.0.2', 55555, 80);

    my $h;
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port6],
        on_connect => sub {
            my $handle = shift;
            $handle->push_write($proxy_header);
            $handle->push_write("GET / HTTP/1.1\r\n");
            $handle->push_write("Host: localhost\r\n");
            $handle->push_write("Connection: close\r\n");
            $handle->push_write("\r\n");
        },
        on_error => sub { $_[0]->destroy; $cv->end; },
        timeout => 3,
    );

    $h->push_read(regex => qr/\r\n\r\n/, sub {
        my ($handle, $header_data) = @_;
        my ($status) = $header_data =~ m{HTTP/1\.\d (\d{3})};
        is($status, 200, 'Native interface: response OK');
        $handle->on_eof(sub { $handle->destroy; $cv->end; });
        $handle->on_read(sub { });
    });

    $cv->recv;

    is($native_env{remote_address}, '172.16.0.1', 'Native interface: remote_address from PROXY');
    is($native_env{remote_port}, '55555', 'Native interface: remote_port from PROXY');
}

# ========================================
# Test group 7: Edge cases
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_keepalive(0);

    my ($socket7, $port7) = get_listen_socket();
    push @keep_alive_sockets, $socket7;
    my $evh7 = Feersum->new;
    $evh7->use_socket($socket7);

    my %env7;
    $evh7->psgi_request_handler(sub {
        my $env = shift;
        %env7 = (REMOTE_ADDR => $env->{REMOTE_ADDR});
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    # Test: Long but valid v1 header
    {
        my $proxy_header = build_proxy_v1('TCP6',
            '2001:0db8:0000:0000:0000:0000:0000:0001',
            '2001:0db8:0000:0000:0000:0000:0000:0002',
            65535, 65535);
        proxy_client_to_port($port7, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'Long but valid v1 header: OK');
        });
    }

    # Test: PROXY v2 with minimum required address data
    {
        my $proxy_header = build_proxy_v2('PROXY', 'INET', '1.2.3.4', '5.6.7.8', 1234, 80);
        proxy_client_to_port($port7, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v2 with minimum required: OK');
        });
        is($env7{REMOTE_ADDR}, '1.2.3.4', 'PROXY v2: REMOTE_ADDR from header');
    }
}

# ========================================
# Test group 8: TLV parsing (native interface only)
# ========================================
{
    Feersum->set_proxy_protocol(1);

    my ($socket8, $port8) = get_listen_socket();
    push @keep_alive_sockets, $socket8;
    my $evh8 = Feersum->new;
    $evh8->use_socket($socket8);

    my %native_result;
    $evh8->request_handler(sub {
        my $req = shift;
        %native_result = (
            remote_address => $req->remote_address,
            proxy_tlvs     => $req->proxy_tlvs,
            env_tlvs       => $req->env->{'psgix.proxy_tlvs'},
        );
        $req->send_response(200, ['Content-Type' => 'text/plain'], \'ok');
    });

    # Test: PROXY v2 with TLVs
    {
        my $cv = AE::cv;
        $cv->begin;

        # TLV types: 0x02 = authority, 0x05 = unique_id
        my @tlvs = (
            [0x02, 'example.com'],        # PP2_TYPE_AUTHORITY
            [0x05, 'abc123'],             # PP2_TYPE_UNIQUE_ID
        );
        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.1', '10.0.0.2', 9999, 80, \@tlvs);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port8],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            my ($status) = $header_data =~ m{HTTP/1\.\d (\d{3})};
            is($status, 200, 'TLV test: response OK');
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{remote_address}, '10.0.0.1', 'TLV test: remote_address correct');
        ok(defined $native_result{proxy_tlvs}, 'TLV test: proxy_tlvs is defined');
        is(ref($native_result{proxy_tlvs}), 'HASH', 'TLV test: proxy_tlvs is hashref');
        is($native_result{proxy_tlvs}{'2'}, 'example.com', 'TLV test: authority TLV parsed');
        is($native_result{proxy_tlvs}{'5'}, 'abc123', 'TLV test: unique_id TLV parsed');
        is(ref($native_result{env_tlvs}), 'HASH', 'TLV test: psgix.proxy_tlvs present in env');
        is($native_result{env_tlvs}{'2'}, 'example.com', 'TLV test: env authority TLV matches');
    }

    # Test: PROXY v2 without TLVs returns undef for proxy_tlvs
    {
        my $cv = AE::cv;
        $cv->begin;

        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.3', '10.0.0.4', 8888, 80);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port8],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{remote_address}, '10.0.0.3', 'No TLV test: remote_address correct');
        ok(!defined $native_result{proxy_tlvs}, 'No TLV test: proxy_tlvs is undef');
        ok(!defined $native_result{env_tlvs}, 'No TLV test: psgix.proxy_tlvs absent from env');
    }

    # Test: PROXY v1 (no TLVs possible)
    {
        my $cv = AE::cv;
        $cv->begin;

        my $proxy_header = build_proxy_v1('TCP4', '10.0.0.5', '10.0.0.6', 7777, 80);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port8],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{remote_address}, '10.0.0.5', 'PROXY v1 test: remote_address correct');
        ok(!defined $native_result{proxy_tlvs}, 'PROXY v1 test: proxy_tlvs is undef (v1 has no TLVs)');
    }

    # Test: PROXY v2 with >64 TLVs is rejected with 400 (DoS guard)
    {
        my $cv = AE::cv;
        $cv->begin;
        %native_result = (); # reset

        my @tlvs = map { [0xEE, ''] } 1..65; # 65 minimal TLVs (type=0xEE, zero-length)
        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.7', '10.0.0.8', 1111, 80, \@tlvs);

        my $status_line;
        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port8],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(line => sub {
            (undef, $status_line) = @_;
            $h->on_eof(sub { $h->destroy; $cv->end; });
            $h->on_read(sub { });
        });

        $cv->recv;

        like($status_line, qr{^HTTP/1\.[01] 400 }, 'TLV overflow test: 65 TLVs rejected with 400');
        ok(!defined $native_result{remote_address}, 'TLV overflow test: handler never invoked');
    }
}

# ========================================
# Test group 9: url_scheme inference from PROXY protocol
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_reverse_proxy(0);
    Feersum->set_keepalive(0);

    my ($socket9, $port9) = get_listen_socket();
    push @keep_alive_sockets, $socket9;
    my $evh9 = Feersum->new;
    $evh9->use_socket($socket9);

    my %native_result;
    $evh9->request_handler(sub {
        my $req = shift;
        %native_result = (
            url_scheme => $req->url_scheme,
            remote_address => $req->remote_address,
        );
        $req->send_response(200, ['Content-Type' => 'text/plain'], \'ok');
    });

    # Test: PROXY v1 with dst_port=443 -> https
    {
        my $cv = AE::cv;
        $cv->begin;

        my $proxy_header = build_proxy_v1('TCP4', '10.0.0.1', '10.0.0.2', 12345, 443);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port9],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{url_scheme}, 'https', 'PROXY v1 dst_port=443: url_scheme is https');
    }

    # Test: PROXY v1 with dst_port=80 -> http
    {
        my $cv = AE::cv;
        $cv->begin;

        my $proxy_header = build_proxy_v1('TCP4', '10.0.0.1', '10.0.0.2', 12345, 80);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port9],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{url_scheme}, 'http', 'PROXY v1 dst_port=80: url_scheme is http');
    }

    # Test: PROXY v2 with dst_port=443 -> https
    {
        my $cv = AE::cv;
        $cv->begin;

        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.1', '10.0.0.2', 12345, 443);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port9],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{url_scheme}, 'https', 'PROXY v2 dst_port=443: url_scheme is https');
    }

    # Test: PROXY v2 with PP2_TYPE_SSL TLV -> https (overrides port)
    {
        my $cv = AE::cv;
        $cv->begin;

        # PP2_TYPE_SSL (0x20) with minimal SSL struct:
        # - client (1 byte): flags
        # - verify (4 bytes): verification result
        # The presence of PP2_TYPE_SSL indicates SSL was used
        my $ssl_data = pack('C N', 0x01, 0);  # client=1, verify=0 (success)
        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.1', '10.0.0.2', 12345, 80, [[0x20, $ssl_data]]);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port9],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($native_result{url_scheme}, 'https', 'PROXY v2 PP2_TYPE_SSL: url_scheme is https (overrides port 80)');
    }

    # Test: PSGI interface also gets correct scheme
    my ($socket9b, $port9b) = get_listen_socket();
    push @keep_alive_sockets, $socket9b;
    my $evh9b = Feersum->new;
    $evh9b->use_socket($socket9b);

    my %psgi_result;
    $evh9b->psgi_request_handler(sub {
        my $env = shift;
        %psgi_result = (
            url_scheme => $env->{'psgi.url_scheme'},
            REMOTE_ADDR => $env->{REMOTE_ADDR},
        );
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });

    # Test: PSGI with PROXY v2 dst_port=443
    {
        my $cv = AE::cv;
        $cv->begin;

        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.5', '10.0.0.6', 54321, 443);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port9b],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($psgi_result{url_scheme}, 'https', 'PSGI: PROXY v2 dst_port=443 -> psgi.url_scheme is https');
    }

    # Test: PSGI with PP2_TYPE_SSL TLV
    {
        my $cv = AE::cv;
        $cv->begin;

        my $ssl_data = pack('C N', 0x01, 0);
        my $proxy_header = build_proxy_v2('PROXY', 'INET', '10.0.0.7', '10.0.0.8', 11111, 8080, [[0x20, $ssl_data]]);

        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port9b],
            on_connect => sub {
                my $handle = shift;
                $handle->push_write($proxy_header);
                $handle->push_write("GET / HTTP/1.1\r\n");
                $handle->push_write("Host: localhost\r\n");
                $handle->push_write("Connection: close\r\n");
                $handle->push_write("\r\n");
            },
            on_error => sub { $_[0]->destroy; $cv->end; },
            timeout => 3,
        );

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my ($handle, $header_data) = @_;
            $handle->on_eof(sub { $handle->destroy; $cv->end; });
            $handle->on_read(sub { });
        });

        $cv->recv;

        is($psgi_result{url_scheme}, 'https', 'PSGI: PP2_TYPE_SSL TLV -> psgi.url_scheme is https');
    }
}

# ========================================
# Test group 10: Proxy protocol edge cases
# ========================================
{
    Feersum->set_proxy_protocol(1);
    Feersum->set_keepalive(0);

    my ($socket10, $port10) = get_listen_socket();
    push @keep_alive_sockets, $socket10;
    my $evh10 = Feersum->new;
    $evh10->use_socket($socket10);

    my %env10;
    $evh10->psgi_request_handler(sub {
        my $env = shift;
        %env10 = (
            REMOTE_ADDR => $env->{REMOTE_ADDR},
            url_scheme  => $env->{'psgi.url_scheme'},
        );
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });

    # Test: PROXY v2 PROXY command with UNSPEC family (keeps original address)
    {
        my $proxy_header = build_proxy_v2('PROXY', 'UNSPEC');
        proxy_client_to_port($port10, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v2 PROXY+UNSPEC: response OK');
        });
        is($env10{REMOTE_ADDR}, '127.0.0.1', 'PROXY v2 PROXY+UNSPEC: keeps original address');
        is($env10{url_scheme}, 'http', 'PROXY v2 PROXY+UNSPEC: url_scheme is http');
    }

    # Test: PROXY v2 PROXY command with AF_UNIX family (keeps original address;
    # must be accepted, not rejected with 400 - RFC/spec section 2.2)
    {
        %env10 = ();
        my $proxy_header = build_proxy_v2('PROXY', 'UNIX', '/run/src.sock', '/run/dst.sock');
        proxy_client_to_port($port10, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'PROXY v2 PROXY+UNIX: accepted (not rejected with 400)');
        });
        is($env10{REMOTE_ADDR}, '127.0.0.1', 'PROXY v2 PROXY+UNIX: keeps original address');
        is($env10{url_scheme}, 'http', 'PROXY v2 PROXY+UNIX: url_scheme is http');
    }

    # Test: PROXY v1 with invalid port (>65535) - should be rejected
    {
        my $bad_header = "PROXY TCP4 1.2.3.4 5.6.7.8 99999 80\r\n";
        proxy_client_to_port($port10, $bad_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/, 'PROXY v1 invalid port >65535: rejected');
        });
    }

    # Test: PROXY v1 with invalid IP address - should be rejected
    {
        my $bad_header = "PROXY TCP4 not-an-ip 5.6.7.8 1234 80\r\n";
        proxy_client_to_port($port10, $bad_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/, 'PROXY v1 invalid IP: rejected');
        });
    }

    # Test: PROXY v1 line too long (>107 chars before CRLF)
    {
        my $long_addr = '1.2.3.4 ' x 20;  # ~160 chars total
        my $bad_header = "PROXY TCP4 ${long_addr}1234 80\r\n";
        proxy_client_to_port($port10, $bad_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/, 'PROXY v1 line too long: rejected');
        });
    }

    # PROXY v1 terminated with a bare LF instead of CRLF is rejected, and the
    # trailing "X\r\n" is what makes it visible: a header scan that ran on to
    # the next CRLF would absorb it and leave a complete, valid request behind.
    {
        my $bad_header = "PROXY TCP4 192.0.2.77 10.0.0.1 4711 80\nX\r\n";
        proxy_client_to_port($port10, $bad_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            like($hdr->{Status}, qr/^4\d\d$/,
                 'PROXY v1 with bare LF: rejected, not run on to the next CRLF');
        });
    }

    # Test: Server still works after edge case rejections
    {
        my $proxy_header = build_proxy_v1('TCP4', '172.20.0.1', '172.20.0.2', 22222, 80);
        proxy_client_to_port($port10, $proxy_header, 'GET', '/', sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'After edge cases: server still works');
        });
        is($env10{REMOTE_ADDR}, '172.20.0.1', 'After edge cases: REMOTE_ADDR correct');
    }
}

pass('all tests completed');
