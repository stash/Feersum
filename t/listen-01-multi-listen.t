#!perl
use warnings;
use strict;
use Test::More tests => 13;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

# Create two listening sockets on different ports
my ($socket1, $port1) = get_listen_socket();
ok $socket1, "created first listen socket on port $port1";

my ($socket2, $port2) = get_listen_socket();
ok $socket2, "created second listen socket on port $port2";

isnt $port1, $port2, "ports are different ($port1 vs $port2)";

# Set up a single Feersum server instance (the singleton)
my $evh = Feersum->endjinn;
{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        fail "Died during request handler: $err";
    };
}

# Attach both sockets to the same server
$evh->use_socket($socket1);
$evh->use_socket($socket2);

# Set a PSGI handler that echoes back the SERVER_PORT from the env
$evh->psgi_request_handler(sub {
    my $env = shift;
    my $port = $env->{SERVER_PORT};
    return [
        200,
        ['Content-Type' => 'text/plain', 'Connection' => 'close'],
        ["port=$port"],
    ];
});

# Use a condvar to coordinate the two async requests
my $cv = AE::cv;

# Test request to port 1
$cv->begin;
my $h1;
$h1 = simple_client GET => '/',
    port => $port1,
    name => "port1_client",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "request to port $port1 got 200";
    is $headers->{'content-type'}, 'text/plain',
        "request to port $port1 has correct content-type";
    is $body, "port=$port1",
        "request to port $port1 reports correct SERVER_PORT";
    $cv->end;
    undef $h1;
};

# Test request to port 2
$cv->begin;
my $h2;
$h2 = simple_client GET => '/',
    port => $port2,
    name => "port2_client",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "request to port $port2 got 200";
    is $headers->{'content-type'}, 'text/plain',
        "request to port $port2 has correct content-type";
    is $body, "port=$port2",
        "request to port $port2 reports correct SERVER_PORT";
    $cv->end;
    undef $h2;
};

$cv->recv;
pass "all done";
