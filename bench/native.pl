#!/usr/bin/env perl
# Feersum native app for benchmarking (lower overhead than PSGI)
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use Feersum;
use Socket qw(SOMAXCONN);
use IO::Socket::INET;
use EV;

my $port = $ARGV[0] || 5001;

my $socket = IO::Socket::INET->new(
    LocalAddr => "localhost:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "Cannot create socket: $!";

my $feersum = Feersum->new();
$feersum->use_socket($socket);
$feersum->set_keepalive(1);

my $body = "Hello, World!";

# Native Feersum handler (bypasses PSGI overhead)
$feersum->request_handler(sub {
    my $req = shift;
    $req->send_response(200, ['Content-Type' => 'text/plain'], \$body);
});

print "Feersum native benchmark server on http://127.0.0.1:$port/\n";
EV::run;
