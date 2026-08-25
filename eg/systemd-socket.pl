#!/usr/bin/env perl
# Systemd socket activation example.
#
# Feersum inherits a listen socket from systemd (fd 3) via the
# LISTEN_FDS protocol, avoiding the need to bind to privileged ports.
#
# systemd unit:
#   [Socket]
#   ListenStream=80
#
#   [Service]
#   ExecStart=/usr/bin/perl /path/to/systemd-socket.pl
#   NonBlocking=true        # a [Service] option; systemd ignores it in [Socket]
#
use strict;
use warnings;
use Feersum;
use EV;
use IO::Handle;

my $listen_fds = $ENV{LISTEN_FDS} || 0;
die "Expected LISTEN_FDS=1 from systemd, got $listen_fds\n"
    unless $listen_fds == 1;

# systemd passes the first socket as fd 3
open my $sock, '+<&=', 3 or die "Cannot open fd 3: $!\n";
# Feersum's accept loop requires a NON-BLOCKING listen socket - on a blocking
# one it accepts nothing at all, silently.  Do not rely on the unit file for
# this: set it here so the script is correct either way.
# NB blocking() returns the PREVIOUS state, so `or die` would fire when the
# socket is already non-blocking (i.e. when the unit file got it right).
defined $sock->blocking(0)
    or die "Cannot set fd 3 non-blocking: $!\n";

my $feer = Feersum->new();
$feer->use_socket($sock);
$feer->set_keepalive(1);

$feer->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'],
                      \"Hello from systemd-activated Feersum!\n");
});

# Notify systemd we're ready (sd_notify READY=1)
if (my $notify = $ENV{NOTIFY_SOCKET}) {
    require IO::Socket::UNIX;
    my $s = IO::Socket::UNIX->new(Type => 2, Peer => $notify);  # DGRAM
    $s->send("READY=1") if $s;
}

EV::run;
