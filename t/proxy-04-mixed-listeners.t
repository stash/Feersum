#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

# A rejected connection must carry a real 4xx status: 59x is AnyEvent's own
# synthetic code, and accepting it would let a server that never answers count
# as "rejected".  On the BSDs the reject arrives as a connection error, so the
# synthetic code is still tolerated there.
my $REJECTED = ($^O eq 'linux') ? qr/^4\d\d$/ : qr/^(?:4\d\d|59\d)$/;

BEGIN { plan tests => 22 }

use Feersum;
use AnyEvent;
use AnyEvent::Handle;

# Helper: send raw bytes then HTTP request, read response
sub raw_client {
    my ($port, $prefix, $method, $uri, $cb) = @_;

    my $cv = AE::cv;
    $cv->begin;

    my $response_buf = '';
    my %hdrs;
    my $h;
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        on_connect => sub {
            my $handle = shift;
            $handle->push_write($prefix) if length($prefix);
            $handle->push_write("$method $uri HTTP/1.1\r\n");
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

    $h->push_read(regex => qr/\r\n\r\n/, sub {
        my ($handle, $header_data) = @_;
        my @lines = split(/\r\n/, $header_data);
        my $status_line = shift @lines;
        if ($status_line =~ m{HTTP/(1\.\d) (\d{3})\s*(.*)}) {
            $hdrs{HTTPVersion} = $1;
            $hdrs{Status} = $2;
            $hdrs{Reason} = $3;
        }

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

# ========================================
# Setup: two server instances, different proxy_protocol settings
# ========================================

my @keep;

# Server A: proxy_protocol ON
my $srv_proxy = Feersum->new_instance();
$srv_proxy->set_proxy_protocol(1);
$srv_proxy->set_keepalive(0);

my ($sock_a, $port_a) = get_listen_socket();
push @keep, $sock_a;
$srv_proxy->use_socket($sock_a);

my %env_a;
$srv_proxy->psgi_request_handler(sub {
    my $env = shift;
    %env_a = (
        REMOTE_ADDR => $env->{REMOTE_ADDR},
        REMOTE_PORT => $env->{REMOTE_PORT},
    );
    return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 5], ['proxy']];
});

# Server B: proxy_protocol OFF
my $srv_plain = Feersum->new_instance();
$srv_plain->set_proxy_protocol(0);
$srv_plain->set_keepalive(0);

my ($sock_b, $port_b) = get_listen_socket();
push @keep, $sock_b;
$srv_plain->use_socket($sock_b);

my %env_b;
$srv_plain->psgi_request_handler(sub {
    my $env = shift;
    %env_b = (
        REMOTE_ADDR => $env->{REMOTE_ADDR},
        REMOTE_PORT => $env->{REMOTE_PORT},
    );
    return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 5], ['plain']];
});

# ========================================
# Test 1: PROXY v1 to proxy-enabled listener - works
# ========================================
{
    my $hdr = build_proxy_v1('TCP4', '203.0.113.50', '192.0.2.1', 54321, 80);
    raw_client($port_a, $hdr, 'GET', '/test1', sub {
        my ($body, $hdrs) = @_;
        is $hdrs->{Status}, 200, 'proxy listener + v1 header: 200';
        is $body, 'proxy', 'proxy listener + v1 header: correct body';
    });
    is $env_a{REMOTE_ADDR}, '203.0.113.50', 'proxy listener + v1 header: REMOTE_ADDR from PROXY';
    is $env_a{REMOTE_PORT}, '54321', 'proxy listener + v1 header: REMOTE_PORT from PROXY';
}

# ========================================
# Test 2: PROXY v2 to proxy-enabled listener - works
# ========================================
{
    my $hdr = build_proxy_v2('PROXY', 'INET', '198.51.100.1', '198.51.100.2', 12345, 80);
    raw_client($port_a, $hdr, 'GET', '/test2', sub {
        my ($body, $hdrs) = @_;
        is $hdrs->{Status}, 200, 'proxy listener + v2 header: 200';
        is $body, 'proxy', 'proxy listener + v2 header: correct body';
    });
    is $env_a{REMOTE_ADDR}, '198.51.100.1', 'proxy listener + v2 header: REMOTE_ADDR from PROXY';
    is $env_a{REMOTE_PORT}, '12345', 'proxy listener + v2 header: REMOTE_PORT from PROXY';
}

# ========================================
# Test 3: plain HTTP to non-proxy listener - works
# ========================================
{
    raw_client($port_b, '', 'GET', '/test3', sub {
        my ($body, $hdrs) = @_;
        is $hdrs->{Status}, 200, 'plain listener + no header: 200';
        is $body, 'plain', 'plain listener + no header: correct body';
    });
    is $env_b{REMOTE_ADDR}, '127.0.0.1', 'plain listener + no header: real REMOTE_ADDR';
}

# ========================================
# Test 4: no PROXY header to proxy-enabled listener - rejected
# ========================================
{
    raw_client($port_a, '', 'GET', '/test4', sub {
        my ($body, $hdrs) = @_;
        like $hdrs->{Status}, $REJECTED, 'proxy listener + no header: rejected';
    });
}

# ========================================
# Test 5: PROXY v1 header to non-proxy listener - treated as bad HTTP
# ========================================
{
    my $hdr = build_proxy_v1('TCP4', '203.0.113.50', '192.0.2.1', 54321, 80);
    raw_client($port_b, $hdr, 'GET', '/test5', sub {
        my ($body, $hdrs) = @_;
        like $hdrs->{Status}, $REJECTED, 'plain listener + v1 header: rejected by the server';
    });
}

# ========================================
# Test 6: PROXY v2 header to non-proxy listener - treated as bad HTTP
# ========================================
{
    my $hdr = build_proxy_v2('PROXY', 'INET', '198.51.100.1', '198.51.100.2', 12345, 80);
    raw_client($port_b, $hdr, 'GET', '/test6', sub {
        my ($body, $hdrs) = @_;
        like $hdrs->{Status}, $REJECTED, 'plain listener + v2 header: rejected by the server';
    });
}

# ========================================
# Test 7: both listeners serve concurrently (interleaved)
# ========================================
{
    my $hdr = build_proxy_v1('TCP4', '10.0.0.1', '10.0.0.2', 9999, 80);
    raw_client($port_a, $hdr, 'GET', '/test7a', sub {
        my ($body, $hdrs) = @_;
        is $hdrs->{Status}, 200, 'interleaved: proxy listener OK';
        is $body, 'proxy', 'interleaved: proxy body';
    });
    is $env_a{REMOTE_ADDR}, '10.0.0.1', 'interleaved: proxy REMOTE_ADDR';

    raw_client($port_b, '', 'GET', '/test7b', sub {
        my ($body, $hdrs) = @_;
        is $hdrs->{Status}, 200, 'interleaved: plain listener OK';
        is $body, 'plain', 'interleaved: plain body';
    });
    is $env_b{REMOTE_ADDR}, '127.0.0.1', 'interleaved: plain REMOTE_ADDR';

    # Back to proxy listener
    $hdr = build_proxy_v1('TCP4', '172.16.0.1', '172.16.0.2', 8888, 80);
    raw_client($port_a, $hdr, 'GET', '/test7c', sub {
        my ($body, $hdrs) = @_;
        is $hdrs->{Status}, 200, 'interleaved: proxy listener again OK';
    });
    is $env_a{REMOTE_ADDR}, '172.16.0.1', 'interleaved: proxy REMOTE_ADDR updated';
}
