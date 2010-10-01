#!/usr/bin/env perl
use warnings;
use strict;
use blib;

$SIG{PIPE} = 'IGNORE';

use Feersum;

use IO::Socket::INET;
my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:5000',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
    ReuseAddr => 1,
);

my $counter = 0;
my $evh = Feersum->new();
$evh->use_socket($socket);
$evh->request_handler(sub {
    my $r = shift;
    my $n = $counter++;
    my $env = $r->env;
    $r->send_response("200 OK", [
        'Content-Type' => 'text/plain',
        'Connection' => 'close',
    ], \"Hello customer number $n\n");
});

my $t = EV::timer 1, 1, sub {
    print "served $counter\n";
};

EV::loop;
