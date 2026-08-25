#!/usr/bin/env perl
# PSGI benchmark server with prefork and keepalive
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use Plack::Handler::Feersum;
use Plack::Util;
use Getopt::Long;

my $port = 5000;
my $workers = 3;
my $keepalive = 1;
my $app_file = 'bench/app.psgi';

GetOptions(
    'port=i' => \$port,
    'workers=i' => \$workers,
    'keepalive!' => \$keepalive,
    'app=s' => \$app_file,
) or die "Usage: $0 [--port PORT] [--workers N] [--keepalive|--no-keepalive] [--app FILE]\n";

my $app = Plack::Util::load_psgi($app_file);

# Use Plack::Handler::Feersum which properly sets psgi_request_handler
my $runner = Plack::Handler::Feersum->new(
    listen => ["127.0.0.1:$port"],
    pre_fork => $workers,
    keepalive => $keepalive,
);

my $mode = $keepalive ? "keepalive" : "no-keepalive";
print "PSGI prefork server on http://127.0.0.1:$port/ (workers: $workers, $mode)\n";
$runner->run($app);
