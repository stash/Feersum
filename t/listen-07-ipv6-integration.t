#!perl
# IPv6 integration test - tests actual IPv6 connections, not just address parsing
use warnings;
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use Test::Fatal;
use lib 't'; use Utils;

# Check if IPv6 is available on this system
my $ipv6_available = eval {
    require IO::Socket::IP;
    require Socket;
    Socket->import(qw(AF_INET6));
    # Try to create an IPv6 socket to test availability
    my $sock = IO::Socket::IP->new(
        LocalHost => '::1',
        LocalPort => 0,
        Listen    => 1,
        ReuseAddr => 1,
        Family    => AF_INET6(),
    );
    $sock ? 1 : 0;
};

if (!$ipv6_available) {
    plan skip_all => "IPv6 not available on this system: $@";
} else {
    plan tests => 10;
}

use_ok('Feersum');

# Create an IPv6 listening socket (kernel-assigned ephemeral port)
my $socket = IO::Socket::IP->new(
    LocalHost => '::1',
    LocalPort => 0,
    Listen    => Socket::SOMAXCONN(),
    Family    => Socket::AF_INET6(),
    Blocking  => 0,
);
my $port = $socket ? $socket->sockport : undef;

ok $socket, "created IPv6 listen socket on ::1";
ok $port, "got port $port";

my $evh = Feersum->new();
is exception { $evh->use_socket($socket) }, undef, "bound to IPv6 socket";

my $request_count = 0;
my $last_remote_addr = '';

$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    $request_count++;
    $last_remote_addr = $env->{REMOTE_ADDR} || '';
    $r->send_response(200,
        ["Content-Type" => "text/plain"],
        "Hello IPv6!");
});

my $cv = AE::cv;
my $got_response = '';

$cv->begin;
my $h; $h = AnyEvent::Handle->new(
    connect => ['::1', $port],
    on_connect => sub {
        pass "connected to IPv6 server";
        $h->push_write("GET / HTTP/1.0\r\nHost: [::1]:$port\r\n\r\n");
    },
    on_error => sub {
        my ($handle, $fatal, $msg) = @_;
        # Connection close after response is normal for HTTP/1.0
        if ($got_response) {
            $cv->end;
        } else {
            fail "IPv6 connection error: $msg";
            $cv->end;
        }
        undef $h;
    },
    on_eof => sub {
        $cv->end;
        undef $h;
    },
    on_read => sub {
        my $handle = shift;
        $got_response .= $handle->{rbuf};
        $handle->{rbuf} = '';
    },
    timeout => 3 * TIMEOUT_MULT,
);

my $guard; $guard = AE::timer 3 * TIMEOUT_MULT, 0, sub {
    $cv->croak("TEST TIMEOUT");
};

is exception { $cv->recv }, undef, "request completed";

like $got_response, qr/200 OK/, "got 200 OK response";
like $got_response, qr/Hello IPv6/, "got expected body";
is $request_count, 1, "handled 1 IPv6 request";

# Verify REMOTE_ADDR is an IPv6 address
like $last_remote_addr, qr/^::1$|^0:0:0:0:0:0:0:1$/,
    "REMOTE_ADDR is IPv6 loopback: $last_remote_addr";
