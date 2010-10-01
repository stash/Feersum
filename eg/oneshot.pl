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

my $evh = Feersum->new();
$evh->use_socket($socket);
$evh->request_handler(sub {
    my $r = shift;
    my $n = "only";
    my $w = $r->start_streaming("200 OK", [
        'Content-Type' => 'text/plain',
        'Connection' => 'close',
    ]);
    $w->write("Hello customer number ");
    $w->write(\$n);
    $w->write("\n");
    $w->close();
    $evh->graceful_shutdown(sub { EV::unloop });
});

EV::loop;
