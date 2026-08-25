#!/usr/bin/env perl
# The shape an operator actually deploys, with the knobs that matter and why.
# Feersum::Runner serves a native app.  For a PSGI app use
# Plack::Handler::Feersum with the same options, or bin/feersum, which takes
# the non-code ones as flags.
#
#   perl eg/production.pl
#   kill -QUIT <pid>     # graceful: drains in flight, then exits
use strict;
use warnings;
use Feersum::Runner;

Feersum::Runner->new(
    listen   => ['0.0.0.0:5000'],
    app_file => 'eg/app.feersum',

    # One worker per core is the usual starting point.  reuseport gives each
    # worker its own accept queue instead of a shared one - better balance,
    # but see the note in the docs about combining it with retirement.
    pre_fork  => 4,
    reuseport => 0,

    # Recycle a worker after N requests to cap the damage a leaky app does.
    # graceful_timeout bounds the drain, so a stuck connection cannot hold
    # the slot open for ever.
    max_requests_per_worker => 10_000,
    graceful_timeout        => 30,

    # Load the app once in the master so workers share its memory
    # copy-on-write.  Turn it off if your app opens handles at load time
    # that must not be shared (database connections, most of all).
    preload_app => 1,
    after_fork  => sub { srand; },   # reseed per worker; reconnect DBs here

    # Timeouts.  read_timeout resets on progress, header_timeout does not -
    # it is the slowloris bound.  write_timeout defers while the peer is
    # still draining, so a slow-but-honest client is not cut off.
    read_timeout   => 30,
    header_timeout => 10,
    write_timeout  => 60,

    # Resource ceilings.  max_connections is the one to lower first if you
    # are exposed directly to the internet.
    max_connections => 2_000,
    max_body_len    => 8 * 1024 * 1024,
    max_read_buf    => 4 * 1024 * 1024,

    # One line per completed response: method, uri, seconds.  STDERR, since
    # workers exit via POSIX::_exit and would drop buffered STDOUT.
    access_log => sub {
        my ($method, $uri, $elapsed) = @_;
        warn sprintf "%s %s %.1fms\n", $method, $uri, $elapsed * 1000;
    },

    quiet => 0,
)->run;
