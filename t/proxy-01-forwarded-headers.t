#!perl
use warnings;
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More tests => 24;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();
$evh->set_reverse_proxy(1);
$evh->use_socket($socket);

$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    my $tn = $env->{HTTP_X_TEST_NUM} || 0;

    if ($tn == 1) {
        is $env->{REMOTE_ADDR}, '1.2.3.4', "X-Forwarded-For: single IP";
        is $env->{'psgi.url_scheme'}, 'https', "X-Forwarded-Proto: single scheme";
    }
    elsif ($tn == 2) {
        is $env->{REMOTE_ADDR}, '1.2.3.4', "X-Forwarded-For: multiple IPs (leftmost used)";
        is $env->{'psgi.url_scheme'}, 'https', "X-Forwarded-Proto: multiple schemes (leftmost used)";
    }
    elsif ($tn == 3) {
        is $env->{REMOTE_ADDR}, '1.2.3.4', "X-Forwarded-For: space-separated IPs (leftmost used)";
    }
    elsif ($tn == 4) {
        is $env->{REMOTE_ADDR}, '2001:db8:85a3::8a2e:370:7334', "X-Forwarded-For: IPv6";
    }
    elsif ($tn == 5) {
        is $env->{REMOTE_ADDR}, '1.2.3.4', "X-Forwarded-For: multiple headers (first used)";
        is $env->{'psgi.url_scheme'}, 'https', "X-Forwarded-Proto: multiple headers (first used)";
    }
    elsif ($tn == 6) {
        # Invalid IP in X-Forwarded-For should fall back to real remote addr
        isnt $env->{REMOTE_ADDR}, 'not-an-ip', "X-Forwarded-For: invalid IP falls back";
        like $env->{REMOTE_ADDR}, qr/^(?:127\.0\.0\.1|::1)$/, "falls back to localhost";
    }

    $r->send_response(200, ['Content-Type' => 'text/plain', 'Connection' => 'close'], ["OK $tn"]);
});

my $cv = AE::cv;

# Test 1: Single values
$cv->begin;
my $w1 = simple_client GET => "/",
    headers => {
        'x-test-num' => 1,
        'X-Forwarded-For' => '1.2.3.4',
        'X-Forwarded-Proto' => 'https',
    },
    sub {
        my ($body, $headers) = @_;
        is $body, "OK 1", "test 1 body";
        $cv->end;
    };

# Test 2: Comma-separated multiple values
$cv->begin;
my $w2 = simple_client GET => "/",
    headers => {
        'x-test-num' => 2,
        'X-Forwarded-For' => '1.2.3.4, 5.6.7.8, 9.10.11.12',
        'X-Forwarded-Proto' => 'https, http',
    },
    sub {
        my ($body, $headers) = @_;
        is $body, "OK 2", "test 2 body";
        $cv->end;
    };

# Test 3: Space-separated values (some proxies do this)
$cv->begin;
my $w3 = simple_client GET => "/",
    headers => {
        'x-test-num' => 3,
        'X-Forwarded-For' => '1.2.3.4 5.6.7.8',
    },
    sub {
        my ($body, $headers) = @_;
        is $body, "OK 3", "test 3 body";
        $cv->end;
    };

# Test 4: IPv6
$cv->begin;
my $w4 = simple_client GET => "/",
    headers => {
        'x-test-num' => 4,
        'X-Forwarded-For' => '2001:db8:85a3::8a2e:370:7334',
    },
    sub {
        my ($body, $headers) = @_;
        is $body, "OK 4", "test 4 body";
        $cv->end;
    };

# Test 5: Multiple header instances
$cv->begin;
my $h5 = AnyEvent::Handle->new(
    connect => ['localhost', $port],
    on_error => sub { $cv->end; },
    on_eof => sub { $cv->end; },
);
$h5->push_write(
    "GET / HTTP/1.1\r\n" .
    "Host: localhost\r\n" .
    "X-Test-Num: 5\r\n" .
    "X-Forwarded-For: 1.2.3.4\r\n" .
    "X-Forwarded-For: 5.6.7.8\r\n" .
    "X-Forwarded-Proto: https\r\n" .
    "X-Forwarded-Proto: http\r\n" .
    "Connection: close\r\n\r\n"
);
$h5->on_read(sub {
    if ($h5->rbuf =~ /OK 5/) {
        pass "test 5 succeeded";
        $cv->end;
        $h5->destroy;
    }
});

# Test 6: Invalid IP
$cv->begin;
my $w6 = simple_client GET => "/",
    headers => {
        'x-test-num' => 6,
        'X-Forwarded-For' => 'not-an-ip',
    },
    sub {
        my ($body, $headers) = @_;
        is $body, "OK 6", "test 6 body";
        $cv->end;
    };


$cv->recv;
pass "all done";
