#!/usr/bin/env perl
# Hot restart example - SIGHUP forks a new generation with fresh modules.
#
# Architecture:
#   Master (entry) -> creates listen sockets, manages generations
#   Generation (child) -> loads app + modules fresh, serves requests
#   Workers (grandchildren, if pre_fork) -> handle connections
#
# Usage:
#   perl eg/hot-reload.pl                           # single process
#   perl eg/hot-reload.pl --pre-fork 4              # 4 workers
#   perl eg/hot-reload.pl --pre-fork 4 myapp.feersum  # custom app
#
# The app file is a NATIVE feersum app: Feersum::Runner installs it with
# request_handler.  For a PSGI app:
#   plackup -s Feersum --app-file=app.psgi --hot-restart=1 app.psgi
# (--app-file is required: hot restart re-reads the app from disk.)
#
# Reload (all modules reloaded from scratch):
#   kill -HUP <master-pid>
#
# Stop:
#   kill -QUIT <master-pid>
use strict;
use warnings;
use Feersum::Runner;
use Getopt::Long;

my $port     = 5000;
my $pre_fork = 0;
GetOptions(
    'port=i'     => \$port,
    'pre-fork=i' => \$pre_fork,
);
my $app_file = shift || './eg/app.feersum';

my $runner = Feersum::Runner->new(
    listen      => ["localhost:$port"],
    app_file    => $app_file,
    hot_restart => 1,
    ($pre_fork ? (pre_fork => $pre_fork) : ()),
    quiet       => 0,
);

warn "Master PID $$\n";
warn "Reload: kill -HUP $$\n";
warn "Stop:   kill -QUIT $$\n";
$runner->run;
