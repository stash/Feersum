#!/usr/bin/env perl
# Feersum native app for Unix socket benchmarking
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use Feersum;
use Socket qw(SOMAXCONN);
use IO::Socket::UNIX;
use EV;
use Getopt::Long;
use File::Spec;

my $socket_path = '/tmp/feersum_bench.sock';
my $keepalive = 1;

GetOptions(
    'socket=s' => \$socket_path,
    'keepalive!' => \$keepalive,
) or die "Usage: $0 [--socket PATH] [--keepalive|--no-keepalive]\n";

# Remove existing socket
unlink $socket_path if -S $socket_path;

my $socket = IO::Socket::UNIX->new(
    Local => File::Spec->rel2abs($socket_path),
    Listen => SOMAXCONN,
) or die "Cannot create Unix socket: $!";
$socket->blocking(0) or die "Cannot unblock socket: $!";

my $feersum = Feersum->new();
$feersum->use_socket($socket);
$feersum->set_keepalive($keepalive);

my $body = "Hello, World!";

# Native Feersum handler (bypasses PSGI overhead)
$feersum->request_handler(sub {
    my $req = shift;
    $req->send_response(200, ['Content-Type' => 'text/plain'], \$body);
});

my $mode = $keepalive ? "keepalive" : "no-keepalive";
print "Feersum native Unix socket server on $socket_path ($mode)\n";
print "PID: $$\n";
EV::run;
