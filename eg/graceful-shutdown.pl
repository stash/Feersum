#!/usr/bin/env perl
# Graceful shutdown example - zero-downtime deploy pattern.
# Send SIGQUIT to trigger graceful shutdown: active requests complete,
# new connections are rejected, callback fires when all done.
use strict;
use warnings;
use Feersum;
use EV;
use IO::Socket::INET;
use Socket qw(SOMAXCONN);

my $port = shift || 5000;

my $socket = IO::Socket::INET->new(
    LocalAddr => "0.0.0.0:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "Cannot listen on port $port: $!\n";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

$feer->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'],
                      \"Hello! PID=$$\n");
});

# Graceful shutdown on SIGQUIT
my $quit = EV::signal QUIT => sub {
    print STDERR "Received SIGQUIT, shutting down gracefully...\n";
    $feer->graceful_shutdown(sub {
        print STDERR "All connections drained. Exiting.\n";
        EV::break;
    });
};

print "Feersum on http://localhost:$port/ (PID $$)\n";
print "Graceful shutdown: kill -QUIT $$\n";
EV::run;
