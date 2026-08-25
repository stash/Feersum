#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN { plan tests => 45 }

use Feersum;

# ===========================================================================
# Part 1: Instance creation and config isolation
# ===========================================================================

# Get the default singleton for comparison
my $singleton = Feersum->new();
ok $singleton, "got the default singleton";
isa_ok $singleton, 'Feersum', 'singleton is a Feersum object';

# new_instance() returns a blessed Feersum object
my $inst1 = Feersum->new_instance();
ok $inst1, "new_instance() returned an object";
isa_ok $inst1, 'Feersum', 'instance 1 is a Feersum object';

my $inst2 = Feersum->new_instance();
ok $inst2, "second new_instance() returned an object";
isa_ok $inst2, 'Feersum', 'instance 2 is a Feersum object';

# Instances are all different references
isnt "$inst1", "$singleton", "instance 1 is a different ref from singleton";
isnt "$inst2", "$singleton", "instance 2 is a different ref from singleton";
isnt "$inst1", "$inst2", "instance 1 and 2 are different refs from each other";

# Config is isolated: read_timeout
is $inst1->read_timeout(), 5.0, "instance 1 has default read_timeout of 5.0";
is $inst2->read_timeout(), 5.0, "instance 2 has default read_timeout of 5.0";

$inst1->read_timeout(10.0);
is $inst1->read_timeout(), 10.0, "instance 1 read_timeout changed to 10.0";
is $inst2->read_timeout(), 5.0, "instance 2 read_timeout still 5.0 (isolated)";

# Config is isolated: max_connections
$inst1->max_connections(100);
$inst2->max_connections(200);
is $inst1->max_connections(), 100, "instance 1 max_connections is 100";
is $inst2->max_connections(), 200, "instance 2 max_connections is 200 (isolated)";

# ===========================================================================
# Part 2: Request serving on multiple instances
# ===========================================================================

my $srv1 = Feersum->new_instance();
ok $srv1, "created server instance 1";

my $srv2 = Feersum->new_instance();
ok $srv2, "created server instance 2";

isnt "$srv1", "$srv2", "server instances are different refs";

my ($sock1, $port1) = get_listen_socket();
ok $sock1, "listen socket 1 on port $port1";
$srv1->use_socket($sock1);

my ($sock2, $port2) = get_listen_socket();
ok $sock2, "listen socket 2 on port $port2";
$srv2->use_socket($sock2);

$srv1->request_handler(sub {
    my $req = shift;
    $req->send_response(200, ['Content-Type' => 'text/plain', 'Connection' => 'close'],
        \"instance1");
});

$srv2->request_handler(sub {
    my $req = shift;
    $req->send_response(200, ['Content-Type' => 'text/plain', 'Connection' => 'close'],
        \"instance2");
});

# Send requests to both instances
my $cv = AE::cv;

$cv->begin;
my $h1;
$h1 = simple_client GET => '/',
    port => $port1,
    name => "srv1_client",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "instance 1 returned 200";
    is $body, "instance1", "instance 1 returned correct body";
    $cv->end;
    undef $h1;
};

$cv->begin;
my $h2;
$h2 = simple_client GET => '/',
    port => $port2,
    name => "srv2_client",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "instance 2 returned 200";
    is $body, "instance2", "instance 2 returned correct body";
    $cv->end;
    undef $h2;
};

$cv->recv;

# Verify independent config: change srv1 keepalive, srv2 unaffected
$srv1->set_keepalive(0);
$srv2->set_keepalive(1);

# The section below only re-checked that both servers still respond, which
# is true whatever set_keepalive did.  Assert the settings really are
# per-instance rather than shared.
is $srv1->get_keepalive, 0, "instance 1 kept its own keepalive=0";
is $srv2->get_keepalive, 1, "instance 2 kept its own keepalive=1";

$cv = AE::cv;

$cv->begin;
my $h3;
$h3 = simple_client GET => '/',
    port => $port1,
    name => "srv1_after_config",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "instance 1 still serves after config change";
    is $body, "instance1", "instance 1 still routes correctly";
    $cv->end;
    undef $h3;
};

$cv->begin;
my $h4;
$h4 = simple_client GET => '/',
    port => $port2,
    name => "srv2_after_config",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "instance 2 still serves after config change";
    is $body, "instance2", "instance 2 still routes correctly";
    $cv->end;
    undef $h4;
};

$cv->recv;

# ===========================================================================
# Part 3: Config caching at accept time
# ===========================================================================

# When server config changes mid-flight, new connections should reflect
# the updated config values.

my ($csock, $cport) = get_listen_socket();
ok $csock, "listen socket for cached-config on port $cport";

my $cevh = Feersum->new_instance();
$cevh->use_socket($csock);
$cevh->set_keepalive(1);

my $req_count = 0;
$cevh->request_handler(sub {
    my $req = shift;
    $req_count++;
    $req->send_response(200,
        ['Content-Type' => 'text/plain'],
        \"req=$req_count");
});

# First request with keepalive enabled
$cv = AE::cv;
$cv->begin;
my $ch1;
$ch1 = simple_client GET => '/',
    port => $cport,
    name => "cached_first_req",
    keepalive => 1,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "first request succeeded";
    is $body, "req=1", "got first response";
    $cv->end;
    undef $ch1;
};
$cv->recv;

# Disable keepalive; new connections should get Connection: close
$cevh->set_keepalive(0);

$cv = AE::cv;
$cv->begin;
my $ch2;
$ch2 = simple_client GET => '/',
    port => $cport,
    name => "cached_after_change",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "request after config change succeeded";
    is $body, "req=2", "got second response";
    my $conn_hdr = lc($headers->{connection} || '');
    is $conn_hdr, 'close', "new connection reflects updated config (no keepalive)";
    $cv->end;
    undef $ch2;
};
$cv->recv;

# Restore keepalive and verify new connections use the new setting
$cevh->set_keepalive(1);

$cv = AE::cv;
$cv->begin;
my $ch3;
$ch3 = simple_client GET => '/',
    port => $cport,
    name => "cached_restored",
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "request after restore succeeded";
    is $body, "req=3", "got third response";
    $cv->end;
    undef $ch3;
};
$cv->recv;
