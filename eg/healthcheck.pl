#!/usr/bin/env perl
# Health check endpoint example for Docker / load balancers.
#
# GET /health returns 200 immediately even when the app is busy.
# All other paths go through the normal (potentially slow) app handler.
#
# Docker:
#   HEALTHCHECK --interval=5s CMD curl -f http://localhost:5000/health
#
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
    my $path = $r->path;

    if ($path eq '/health') {
        $r->send_response(200, ['Content-Type' => 'text/plain'],
                          \"ok\n");
        return;
    }

    # Simulate a slow application handler
    my $t; $t = EV::timer(0.1, 0, sub {
        $r->send_response(200, ['Content-Type' => 'text/plain'],
                          \"Hello from the app!\n");
        undef $t;
    });
});

my $quit = EV::signal QUIT => sub {
    $feer->graceful_shutdown(sub { EV::break });
};

print "Feersum on http://0.0.0.0:$port/ (healthcheck: /health)\n";
EV::run;
