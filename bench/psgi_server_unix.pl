#!/usr/bin/env perl
# PSGI benchmark server with Unix socket support
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use IO::Socket::UNIX;
use Socket qw(SOMAXCONN);
use EV;
use Feersum;
use Plack::Util;
use Getopt::Long;
use File::Spec;

my $socket_path = '/tmp/feersum_bench.sock';
my $keepalive = 0;
my $app_file = 'bench/app.psgi';

GetOptions(
    'socket=s' => \$socket_path,
    'keepalive!' => \$keepalive,
    'app=s' => \$app_file,
) or die "Usage: $0 [--socket PATH] [--keepalive] [--app FILE]\n";

my $app = Plack::Util::load_psgi($app_file);

# Remove existing socket
unlink $socket_path if -S $socket_path;

my $sock = IO::Socket::UNIX->new(
    Local => File::Spec->rel2abs($socket_path),
    Listen => SOMAXCONN,
) or die "Cannot create Unix socket: $!";
$sock->blocking(0) or die "Cannot unblock socket: $!";

my $f = Feersum->endjinn;
$f->use_socket($sock);
$f->set_keepalive($keepalive);
$f->psgi_request_handler($app);

my $mode = $keepalive ? "keepalive" : "no-keepalive";
print "PSGI Unix socket server on $socket_path ($mode)\n";
print "PID: $$\n";
EV::run;
