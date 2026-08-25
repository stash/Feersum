#!perl
# Test SO_REUSEPORT: two sockets bound to the same port with new_instance().
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

use Feersum;
use Socket qw(SOL_SOCKET SO_REUSEADDR SOCK_STREAM SOMAXCONN
              AF_INET INADDR_LOOPBACK pack_sockaddr_in sockaddr_in);

plan skip_all => "SO_REUSEPORT tests only run on Linux"
    unless $^O eq 'linux';

plan skip_all => "Socket::SO_REUSEPORT not available"
    unless eval { my $v = Socket::SO_REUSEPORT(); defined $v };

# 6 setup + 10 simple_client "connected" + 2 result + 1 skip/pass + 1 final
plan tests => 22;

# Helper: create a raw socket with SO_REUSEADDR + SO_REUSEPORT bound to $port.
# If $port is 0, the OS picks an ephemeral port.
sub make_reuseport_socket {
    my ($port) = @_;
    my $sock;
    socket($sock, AF_INET, SOCK_STREAM, 0)
        or die "socket: $!";
    setsockopt($sock, SOL_SOCKET, SO_REUSEADDR, pack("i", 1))
        or die "SO_REUSEADDR: $!";
    setsockopt($sock, SOL_SOCKET, Socket::SO_REUSEPORT(), pack("i", 1))
        or die "SO_REUSEPORT: $!";
    bind($sock, pack_sockaddr_in($port, INADDR_LOOPBACK))
        or die "bind($port): $!";
    listen($sock, SOMAXCONN)
        or die "listen: $!";

    # Wrap in IO::Handle for ->blocking() method (same as Runner.pm)
    require IO::Handle;
    bless $sock, 'IO::Handle';
    $sock->blocking(0) or die "blocking: $!";

    my ($actual_port) = sockaddr_in(getsockname($sock));
    return ($sock, $actual_port);
}

# Create first socket on an ephemeral port
my ($sock1, $port) = make_reuseport_socket(0);
ok $sock1, "created first SO_REUSEPORT socket";
ok $port > 0, "bound to port $port";

# Create second socket on the SAME port
my ($sock2, $port2) = make_reuseport_socket($port);
ok $sock2, "created second SO_REUSEPORT socket on same port";
is $port2, $port, "both sockets bound to same port $port";

# Create two independent Feersum instances
my $inst1 = Feersum->new_instance();
ok $inst1, "created Feersum instance 1";
$inst1->use_socket($sock1);

my $inst2 = Feersum->new_instance();
ok $inst2, "created Feersum instance 2";
$inst2->use_socket($sock2);

# Set different request handlers
$inst1->request_handler(sub {
    my $req = shift;
    $req->send_response(200,
        ['Content-Type' => 'text/plain', 'Connection' => 'close'],
        \"from-inst1");
});

$inst2->request_handler(sub {
    my $req = shift;
    $req->send_response(200,
        ['Content-Type' => 'text/plain', 'Connection' => 'close'],
        \"from-inst2");
});

# Send several requests - with SO_REUSEPORT the kernel distributes them.
# We just need at least one successful response to prove both instances
# are functional on the same port.
my $cv = AE::cv;
my %seen;
my @handles;

my $total = 10;
$cv->begin for 1 .. $total;

for my $i (1 .. $total) {
    my $h;
    $h = simple_client GET => '/',
        port => $port,
        name => "reuseport_client_$i",
    sub {
        my ($body, $headers) = @_;
        if ($headers->{Status} == 200 && $body) {
            $seen{$body}++;
        }
        $cv->end;
        undef $h;
    };
    push @handles, $h;
}

$cv->recv;

# At least one instance must have served a request
my $served = ($seen{'from-inst1'} || 0) + ($seen{'from-inst2'} || 0);
ok $served > 0, "got $served successful responses on shared port";
ok $served == $total, "all $total requests were served";

# The kernel may or may not distribute to both - we just verify both sockets
# accepted use_socket without error and at least one served traffic.
# On most kernels both will get traffic, but we don't mandate it.
my $both = exists $seen{'from-inst1'} && exists $seen{'from-inst2'};
SKIP: {
    skip "kernel didn't distribute to both (not required)", 1 unless $both;
    pass "both instances served requests on the same port";
}

pass "SO_REUSEPORT dual-bind test complete";

# Everything above builds sockets by hand, so nothing exercised Runner's own
# _create_socket() reuseport branch - which is how a broken port-validation
# regex there once shipped, croaking "invalid port" on every --reuseport run.
require Feersum::Runner;
for my $listen ("127.0.0.1:0", "localhost:0") {
    my $runner = Feersum::Runner->new(
        listen => [$listen], app_file => '/dev/null',
        pre_fork => 2, reuseport => 1, quiet => 1,
    );
    my $sock = eval { $runner->_create_socket($listen, 1) };
    ok $sock, "Runner reuseport socket for '$listen'"
        or diag "croaked: $@";
    close $sock if $sock;
}
