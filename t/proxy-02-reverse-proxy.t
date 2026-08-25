#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN { plan tests => 35 }

use Feersum;

# Test get/set singleton methods
is(Feersum->get_reverse_proxy, 0, 'default is off');
Feersum->set_reverse_proxy(1);
is(Feersum->get_reverse_proxy, 1, 'enabled via class method');

my $f = Feersum->new;
is($f->get_reverse_proxy, 1, 'instance sees global setting');
$f->set_reverse_proxy(0);
is(Feersum->get_reverse_proxy, 0, 'instance method affects global');

# Test PSGI env with reverse_proxy enabled
Feersum->set_reverse_proxy(1);

my ($socket, $port) = get_listen_socket();
my $evh = Feersum->new;
$evh->use_socket($socket);

my %captured_env;
$evh->psgi_request_handler(sub {
    my $env = shift;
    %captured_env = map { $_ => $env->{$_} }
        qw(REMOTE_ADDR psgi.url_scheme);
    return [200, ['Content-Type' => 'text/plain'], ['ok']];
});

# Test with X-Forwarded headers
{
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/',
        headers => {
            'X-Forwarded-For' => '203.0.113.50, 10.0.0.1, 192.168.1.1',
            'X-Forwarded-Proto' => 'https',
        },
        sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'request ok');
            $cv->end;
        };
    $cv->recv;

    is($captured_env{'REMOTE_ADDR'}, '203.0.113.50',
        'REMOTE_ADDR from X-Forwarded-For (first IP)');
    is($captured_env{'psgi.url_scheme'}, 'https',
        'psgi.url_scheme from X-Forwarded-Proto');
}

# Test without X-Forwarded headers (should use real values)
{
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/',
        sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'request ok');
            $cv->end;
        };
    $cv->recv;

    is($captured_env{'REMOTE_ADDR'}, '127.0.0.1',
        'REMOTE_ADDR fallback to real IP');
    is($captured_env{'psgi.url_scheme'}, 'http',
        'psgi.url_scheme fallback to http');
}

# Test with reverse_proxy disabled
Feersum->set_reverse_proxy(0);
{
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/',
        headers => {
            'X-Forwarded-For' => '203.0.113.50',
            'X-Forwarded-Proto' => 'https',
        },
        sub {
            my ($body, $hdr) = @_;
            is($hdr->{Status}, 200, 'request ok');
            $cv->end;
        };
    $cv->recv;

    is($captured_env{'REMOTE_ADDR'}, '127.0.0.1',
        'REMOTE_ADDR ignores X-Forwarded-For when disabled');
    is($captured_env{'psgi.url_scheme'}, 'http',
        'psgi.url_scheme ignores X-Forwarded-Proto when disabled');
}

# Test native interface methods (client_address, url_scheme)
my ($socket2, $port2) = get_listen_socket();
my $evh2 = Feersum->new;
$evh2->use_socket($socket2);

my %native_captured;
$evh2->request_handler(sub {
    my $req = shift;
    %native_captured = (
        client_address => $req->client_address,
        url_scheme     => $req->url_scheme,
        remote_address => $req->remote_address,
    );
    $req->send_response(200, ['Content-Type' => 'text/plain'], \'ok');
});

# Native interface with reverse_proxy enabled
Feersum->set_reverse_proxy(1);
{
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port2,
        headers => {
            'X-Forwarded-For' => '198.51.100.1',
            'X-Forwarded-Proto' => 'https',
        },
        sub { $cv->end };
    $cv->recv;

    is($native_captured{client_address}, '198.51.100.1',
        'native: client_address from X-Forwarded-For');
    is($native_captured{url_scheme}, 'https',
        'native: url_scheme from X-Forwarded-Proto');
    is($native_captured{remote_address}, '127.0.0.1',
        'native: remote_address always real IP');
}

# Native interface without headers
{
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port2, sub { $cv->end };
    $cv->recv;

    is($native_captured{client_address}, '127.0.0.1',
        'native: client_address fallback');
    is($native_captured{url_scheme}, 'http',
        'native: url_scheme fallback');
}

# Native interface with reverse_proxy disabled
Feersum->set_reverse_proxy(0);
{
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port2,
        headers => {
            'X-Forwarded-For' => '198.51.100.1',
            'X-Forwarded-Proto' => 'https',
        },
        sub { $cv->end };
    $cv->recv;

    is($native_captured{client_address}, '127.0.0.1',
        'native: client_address ignores header when disabled');
    is($native_captured{url_scheme}, 'http',
        'native: url_scheme ignores header when disabled');
}

# Test X-Forwarded-For IP validation (invalid IPs should fall back to real REMOTE_ADDR)
# Need a fresh server since Feersum is singleton and handlers were replaced
my ($socket3, $port3) = get_listen_socket();
my $evh3 = Feersum->new;
$evh3->use_socket($socket3);

my %validation_env;
$evh3->psgi_request_handler(sub {
    my $env = shift;
    %validation_env = map { $_ => $env->{$_} }
        qw(REMOTE_ADDR psgi.url_scheme);
    return [200, ['Content-Type' => 'text/plain'], ['ok']];
});
Feersum->set_reverse_proxy(1);

{
    # Test with invalid IP format (hostname instead of IP)
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port3,
        headers => {
            'X-Forwarded-For' => 'localhost, 10.0.0.1',
        },
        sub { $cv->end };
    $cv->recv;

    is($validation_env{'REMOTE_ADDR'}, '127.0.0.1',
        'invalid X-Forwarded-For (hostname) falls back to real IP');
}

{
    # Test with malformed IP (out of range octets)
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port3,
        headers => {
            'X-Forwarded-For' => '999.999.999.999',
        },
        sub { $cv->end };
    $cv->recv;

    is($validation_env{'REMOTE_ADDR'}, '127.0.0.1',
        'invalid X-Forwarded-For (999.999.999.999) falls back to real IP');
}

{
    # Test with valid IPv6 address
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port3,
        headers => {
            'X-Forwarded-For' => '2001:db8::1, 10.0.0.1',
        },
        sub { $cv->end };
    $cv->recv;

    is($validation_env{'REMOTE_ADDR'}, '2001:db8::1',
        'valid IPv6 in X-Forwarded-For is accepted');
}

{
    # Test with completely invalid format
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', port => $port3,
        headers => {
            'X-Forwarded-For' => 'not-an-ip-address',
        },
        sub { $cv->end };
    $cv->recv;

    is($validation_env{'REMOTE_ADDR'}, '127.0.0.1',
        'invalid X-Forwarded-For (random string) falls back to real IP');
}

pass('all done');
