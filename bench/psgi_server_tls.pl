#!/usr/bin/env perl
# PSGI benchmark server with TLS and optional H2
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use IO::Socket::INET;
use EV;
use Feersum;
use Plack::Util;
use Getopt::Long;

my $port     = 5004;
my $keepalive = 1;
my $cert     = 'eg/ssl-proxy/server.crt';
my $key      = 'eg/ssl-proxy/server.key';
my $h2       = 0;
my $app_file = 'bench/app.psgi';

GetOptions(
    'port=i'     => \$port,
    'keepalive!' => \$keepalive,
    'cert=s'     => \$cert,
    'key=s'      => \$key,
    'h2!'        => \$h2,
    'app=s'      => \$app_file,
) or die "Usage: $0 [--port PORT] [--keepalive] [--cert FILE] [--key FILE] [--h2] [--app FILE]\n";

my $app = Plack::Util::load_psgi($app_file);

my $f = Feersum->endjinn;
my $sock = IO::Socket::INET->new(
    LocalAddr => "127.0.0.1:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => 1024,
    Blocking  => 0,
) or die "Cannot create socket: $!";

$f->use_socket($sock);
$f->set_keepalive($keepalive);
$f->read_timeout(300);  # 5min; avoid false idle-timeout under load

die "Feersum not compiled with TLS support\n" unless $f->has_tls();

$f->set_tls(
    cert_file => $cert,
    key_file  => $key,
    ($h2 ? (h2 => 1) : ()),
);

$f->psgi_request_handler($app);

my $proto = $h2 ? "h2" : "https";
my $mode = $keepalive ? "keepalive" : "no-keepalive";
print "PSGI TLS server on https://127.0.0.1:$port/ ($proto, $mode)\n";
EV::run;
