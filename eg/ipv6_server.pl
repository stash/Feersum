#!/usr/bin/env perl
#
# Example: Running Feersum on IPv6
#
# Demonstrates binding to an IPv6 address.
#
# Usage:
#   perl eg/ipv6_server.pl
#
# Then test with:
#   curl -6 'http://[::1]:5000/'
#   curl -6 'http://[::1]:5000/info'
#
use strict;
use warnings;
use Feersum::Runner;

# Check for IPv6 support
BEGIN {
    eval {
        require Socket;
        Socket->import(qw/AF_INET6 inet_pton/);
        inet_pton(AF_INET6(), '::1')
            or die "inet_pton failed";
    } or do {
        die "IPv6 not supported on this system: $@\n";
    };
}

my $app = sub {
    my $r = shift;
    my $path = $r->path;

    if ($path eq '/info') {
        # Show connection info
        my $info = sprintf(
            "Remote: %s:%s\nProtocol: %s\nHTTP/1.1: %s\nKeep-Alive: %s\n",
            $r->remote_address,
            $r->remote_port,
            $r->protocol,
            $r->is_http11 ? 'yes' : 'no',
            $r->is_keepalive ? 'yes' : 'no',
        );
        $r->send_response(200, ['Content-Type' => 'text/plain'], $info);
    }
    else {
        $r->send_response(200, [
            'Content-Type' => 'text/plain',
        ], "Hello from IPv6! Try /info for connection details.\n");
    }
};

print "Starting Feersum on [::1]:5000 (IPv6)...\n";
print "Test with: curl -6 'http://[::1]:5000/'\n";

my $runner = Feersum::Runner->new(
    listen    => ['[::1]:5000'],  # IPv6 localhost: brackets separate the port
    quiet     => 0,
);

$runner->run($app);
