#!/usr/bin/env perl
# Two independent servers in one process, which is what new_instance() is for.
# Feersum->endjinn is a singleton with one handler and one set of tunables;
# new_instance() gives you a second of each, sharing only the event loop.
#
# Here: a public API on 5002 with tight limits, and an admin endpoint on 5003
# with its own handler, its own limits, and its own idea of keepalive.
#
#   perl eg/multi-instance.pl
#   curl localhost:5002/ ; curl localhost:5003/stats
use strict;
use warnings;
use EV;
use Feersum;
use IO::Socket::INET;

sub listener {
    my ($port) = @_;
    IO::Socket::INET->new(
        LocalAddr => "localhost:$port",
        Proto     => 'tcp',
        Listen    => 1024,
        ReuseAddr => 1,
    ) or die "listen on $port: $!";
}

# Public: strangers talk to it, so keep the limits mean.
my $public = Feersum->new_instance;
$public->use_socket(listener(5002));
$public->set_keepalive(1);
$public->max_connections(1000);
$public->max_body_len(64 * 1024);
$public->read_timeout(5);
$public->request_handler(sub {
    my $req = shift;
    $req->send_response(200, ['Content-Type' => 'text/plain'], ["public\n"]);
});

# Admin: fewer, friendlier clients, and it reports on the public instance.
my $admin = Feersum->new_instance;
$admin->use_socket(listener(5003));
$admin->max_connections(10);
$admin->read_timeout(60);
$admin->request_handler(sub {
    my $req = shift;
    my $body = sprintf "public: %d active, %d requests served\nadmin:  %d active\n",
        $public->active_conns, $public->total_requests, $admin->active_conns;
    $req->send_response(200, ['Content-Type' => 'text/plain'], [$body]);
});

# The instances are independent: shutting one down leaves the other serving.
my $quit = EV::signal QUIT => sub {
    warn "draining public, admin stays up\n";
    $public->graceful_shutdown(sub { warn "public drained\n" });
};

warn "public http://localhost:5002/  admin http://localhost:5003/stats\n";
EV::run;
