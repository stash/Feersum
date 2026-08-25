#!/usr/bin/env perl
# TLS server with optional HTTP/2 support.
# Usage: perl eg/tls-server.pl [--h2] [--port 8443]
#
# Generate self-signed certs:
#   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
#     -nodes -keyout server.key -out server.crt -days 365 -subj '/CN=localhost'
use strict;
use warnings;
use Feersum;
use EV;
use IO::Socket::INET;
use Socket qw(SOMAXCONN);
use Getopt::Long;

my $port = 8443;
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
    LocalAddr => "0.0.0.0:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "Cannot listen on port $port: $!\n";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

die "Feersum not compiled with TLS support\n" unless $feer->has_tls();
$feer->set_tls(cert_file => $cert, key_file => $key, ($h2 ? (h2 => 1) : ()));

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $proto = $env->{'psgi.url_scheme'} eq 'https' ? 'HTTPS' : 'HTTP';
    my $h2ver = ($env->{SERVER_PROTOCOL}||'') eq 'HTTP/2' ? ' (HTTP/2)' : '';
    my $body  = "Hello from ${proto}${h2ver}!\nPath: $env->{PATH_INFO}\n";
    [200, ['Content-Type' => 'text/plain'], [$body]];
});

my $proto = $h2 ? 'h2+https' : 'https';
print "Feersum TLS server on https://localhost:$port/ ($proto)\n";
print "Test: curl -k https://localhost:$port/\n";
EV::run;
