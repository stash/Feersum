#!/usr/bin/env perl
# Native Feersum server example (maximum performance)
#
# Usage: perl eg/native.pl [/path/to/socket]
#        perl eg/native.pl /tmp/feersum.sock
#
use warnings;
use strict;
use EV;
use Feersum;
use IO::Socket::UNIX;

my $path = shift || '/tmp/feersum.sock';
unlink $path if -e $path;

my $socket = IO::Socket::UNIX->new(
    Local    => $path,
    Type     => SOCK_STREAM,
    Listen   => 1024,
    Blocking => 0,
) or die "Cannot listen on $path: $!\n";

my $evh = Feersum->new();
$evh->use_socket($socket);
$evh->set_keepalive(1);
$evh->header_timeout(30);

my $counter = 0;
$evh->request_handler(sub {
    my $r = shift;
    my $n = $counter++;
    $r->send_response(200, [
        'Content-Type' => 'text/plain',
    ], \"Hello customer number $n\n");
});

# NB an END block would NOT work here: EV::run never returns, and the default
# SIGQUIT disposition skips END blocks.  Clean the socket up from a signal
# handler instead (same pattern as eg/graceful-shutdown.pl), and install it
# BEFORE entering the loop.
my $cleanup = EV::signal 'QUIT', sub { unlink $path if -e $path; EV::break };

print "Feersum native server listening on unix:$path\n";
EV::run;
unlink $path if -e $path;
