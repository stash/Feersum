#!/usr/bin/env perl
# Feersum native app with TLS for benchmarking
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use Feersum;
use Socket qw(SOMAXCONN);
use IO::Socket::INET;
use EV;
use Getopt::Long;

my $port = 5003;
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
my $h2   = 0;

GetOptions(
    'port=i' => \$port,
    'cert=s' => \$cert,
    'key=s'  => \$key,
    'h2!'    => \$h2,
) or die "Usage: $0 [--port PORT] [--cert FILE] [--key FILE] [--h2]\n";

my $socket = IO::Socket::INET->new(
    LocalAddr => "127.0.0.1:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "Cannot create socket: $!";

my $feersum = Feersum->new();
$feersum->use_socket($socket);
$feersum->set_keepalive(1);
$feersum->read_timeout(300);  # 5min; avoid false idle-timeout under load

die "Feersum not compiled with TLS support\n" unless $feersum->has_tls();

$feersum->set_tls(
    cert_file => $cert,
    key_file  => $key,
    ($h2 ? (h2 => 1) : ()),
);

my $body = "Hello, World!";

$feersum->request_handler(sub {
    my $req = shift;
    $req->send_response(200, ['Content-Type' => 'text/plain'], \$body);
});

my $proto = $h2 ? "h2" : "https";
print "Feersum native TLS server on https://127.0.0.1:$port/ ($proto)\n";
EV::run;
