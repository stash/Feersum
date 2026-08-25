#!/usr/bin/env perl
# PSGI benchmark server with configurable keepalive
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use IO::Socket::INET;
use EV;
use Feersum;
use Plack::Util;
use Getopt::Long;

my $port = 5000;
my $keepalive = 0;
my $app_file = 'bench/app.psgi';

GetOptions(
    'port=i' => \$port,
    'keepalive!' => \$keepalive,
    'app=s' => \$app_file,
) or die "Usage: $0 [--port PORT] [--keepalive] [--app FILE]\n";

my $app = Plack::Util::load_psgi($app_file);

my $f = Feersum->endjinn;
my $sock = IO::Socket::INET->new(
    LocalAddr => "127.0.0.1:$port",
    ReuseAddr => 1,
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
) or die "Cannot create socket: $!";

$f->use_socket($sock);
$f->set_keepalive($keepalive);
$f->psgi_request_handler($app);

my $mode = $keepalive ? "keepalive" : "no-keepalive";
print "PSGI server on http://127.0.0.1:$port/ ($mode)\n";
EV::run;
