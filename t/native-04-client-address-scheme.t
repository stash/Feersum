#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More tests => 16;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

#######################################################################
# Test 1: client_address and url_scheme in normal (non-reverse-proxy) mode
#######################################################################
{
    my $cv = AE::cv;
    my ($got_addr, $got_scheme);

    $feer->request_handler(sub {
        my $r = shift;
        $got_addr = $r->client_address;
        $got_scheme = $r->url_scheme;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
        $cv->send;
    });

    my $w = simple_client GET => '/',
        timeout => 3 * TIMEOUT_MULT,
        sub { };

    $cv->recv;

    is $got_addr, '127.0.0.1', 'client_address returns 127.0.0.1 without reverse_proxy';
    is $got_scheme, 'http', 'url_scheme returns http for plain connection';
}

#######################################################################
# Test 2: client_address with reverse_proxy + X-Forwarded-For
#######################################################################
{
    $feer->set_reverse_proxy(1);

    my $cv = AE::cv;
    my ($got_addr, $got_scheme);

    $feer->request_handler(sub {
        my $r = shift;
        $got_addr = $r->client_address;
        $got_scheme = $r->url_scheme;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
        $cv->send;
    });

    my $w = simple_client GET => '/',
        headers => {
            'X-Forwarded-For'   => '10.0.0.1',
            'X-Forwarded-Proto' => 'https',
        },
        timeout => 3 * TIMEOUT_MULT,
        sub { };

    $cv->recv;

    is $got_addr, '10.0.0.1', 'client_address returns X-Forwarded-For with reverse_proxy';
    is $got_scheme, 'https', 'url_scheme returns https from X-Forwarded-Proto';
}

#######################################################################
# Test 3: client_address falls back to real addr without X-Forwarded-For
#######################################################################
{
    my $cv = AE::cv;
    my ($got_addr, $got_scheme);

    $feer->request_handler(sub {
        my $r = shift;
        $got_addr = $r->client_address;
        $got_scheme = $r->url_scheme;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
        $cv->send;
    });

    my $w = simple_client GET => '/',
        timeout => 3 * TIMEOUT_MULT,
        sub { };

    $cv->recv;

    is $got_addr, '127.0.0.1', 'client_address falls back to real addr without X-Forwarded-For';
    is $got_scheme, 'http', 'url_scheme returns http without X-Forwarded-Proto';
}

#######################################################################
# Test 4: client_address with chained X-Forwarded-For (extracts first)
#######################################################################
{
    my $cv = AE::cv;
    my $got_addr;

    $feer->request_handler(sub {
        my $r = shift;
        $got_addr = $r->client_address;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
        $cv->send;
    });

    my $w = simple_client GET => '/',
        headers => { 'X-Forwarded-For' => '192.168.1.1, 10.0.0.2, 172.16.0.3' },
        timeout => 3 * TIMEOUT_MULT,
        sub { };

    $cv->recv;

    # Should extract the first (leftmost) address
    # A substring match could not detect the bug this targets: if the whole
    # chain were returned, qr/192\.168\.1\.1/ would still match.
    is $got_addr, '192.168.1.1',
        'client_address extracts first addr from chained X-Forwarded-For';
}

#######################################################################
# Test 5: url_scheme without reverse_proxy ignores X-Forwarded-Proto
#######################################################################
{
    $feer->set_reverse_proxy(0);

    my $cv = AE::cv;
    my ($got_addr, $got_scheme);

    $feer->request_handler(sub {
        my $r = shift;
        $got_addr = $r->client_address;
        $got_scheme = $r->url_scheme;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'ok');
        $cv->send;
    });

    my $w = simple_client GET => '/',
        headers => {
            'X-Forwarded-For'   => '10.0.0.1',
            'X-Forwarded-Proto' => 'https',
        },
        timeout => 3 * TIMEOUT_MULT,
        sub { };

    $cv->recv;

    is $got_addr, '127.0.0.1', 'client_address ignores X-Forwarded-For without reverse_proxy';
    is $got_scheme, 'http', 'url_scheme ignores X-Forwarded-Proto without reverse_proxy';
}
