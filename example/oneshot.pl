#!/usr/bin/env perl
use warnings;
use strict;
use blib;

$SIG{PIPE} = 'IGNORE';

use Feersum;
#use AnyEvent;

use IO::Socket::INET;
my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10204',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
    ReuseAddr => 1,
    ReusePort => 1,
);

my $evh = Feersum->new();
$evh->use_socket($socket);
$evh->request_handler(sub {
    my $r = shift;
    my $n = "only";
    my %env;
    $r->env(\%env);
    $r->start_response("200 OK", [
        'Content-Type' => 'text/plain',
        'Connection' => 'close',
    ], 1);
    my $w = $r->write_handle;
    $w->write("Hello customer number ");
    $w->write(\$n);
    $w->write("\n");
    $w->close();
    $evh->graceful_shutdown(sub { EV::unloop });
});

EV::loop;
