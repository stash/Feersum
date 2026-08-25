#!perl
# With set_drain_accept_queue(1) (Feersum::Runner sets it for reuseport
# workers) graceful_shutdown accepts and serves the connections already queued
# on the listen socket instead of dropping them with an RST when the fd closes.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More tests => 16;
use lib 't'; use Utils;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Errno qw(EINTR EAGAIN);

BEGIN { use_ok('Feersum') };

# Read until EOF/error with a deadline; returns (buf, errno-or-undef).
sub drain_client {
    my ($s) = @_;
    my ($buf, $deadline) = ('', time() + 5 * TIMEOUT_MULT);
    while (time() < $deadline) {
        my $rin = '';
        vec($rin, fileno($s), 1) = 1;
        next unless select(my $rout = $rin, undef, undef, 0.25);
        my $got = sysread($s, my $chunk, 65536);
        if (!defined $got) {
            next if $! == EINTR || $! == EAGAIN;
            return ($buf, 0 + $!);
        }
        return ($buf, undef) if $got == 0;
        $buf .= $chunk;
    }
    return ($buf, 'timeout');
}

# Connect and push a full request into the server's kernel accept queue while
# accept is paused; nothing in userspace has seen this connection yet.
sub queue_one_connection {
    my ($port) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => 'localhost', PeerPort => $port,
        Proto => 'tcp', Timeout => 3 * TIMEOUT_MULT,
    ) or return;
    $s->autoflush(1);
    print $s "GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n";
    # TCP_DEFER_ACCEPT: the connection reaches the accept queue only once the
    # request bytes arrive; give loopback a moment to latch them in.
    sleep 0.3 * TIMEOUT_MULT;
    return $s;
}

###############################################################################
# Scenario A: drain_accept_queue enabled - the queued connection must be
# accepted and served before the listener closes.
###############################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "made listen socket";

    my $evh = Feersum->new_instance();
    $evh->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], ["drained\n"]);
    });
    $evh->use_socket($socket);

    ok $evh->can('set_drain_accept_queue'), 'set_drain_accept_queue exists';
  SKIP: {
        skip 'no accessor (pre-fix build)', 2
            unless $evh->can('get_drain_accept_queue');
        is $evh->get_drain_accept_queue, 0, 'drain_accept_queue defaults off';
        $evh->set_drain_accept_queue(1);
        is $evh->get_drain_accept_queue, 1, 'drain_accept_queue turns on';
    }

    ok $evh->pause_accept, 'paused accept (connection stays queued in kernel)';
    my $client = queue_one_connection($port);
    ok $client, 'client connected while accept was paused';

    my $shutdown_fired = 0;
    my $cv = AE::cv;
    my $guard_t = AE::timer 10 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') };
    $evh->graceful_shutdown(sub { $shutdown_fired = 1; $cv->send('done') });
    is $cv->recv, 'done', 'graceful_shutdown completed (did not hang)';
    ok $shutdown_fired, 'shutdown callback fired';

    my ($buf, $err) = drain_client($client);
    # Pre-fix this is an ECONNRESET with no bytes: the close of the listener
    # destroyed the already-established connection.
    like $buf, qr{\AHTTP/1\.1 200 .*\r\n\r\ndrained\n\z}s,
        'queued connection was served during the drain';
    ok !defined $err, 'client saw clean EOF, not a reset'
        or diag "read error: $err";
    close $client;
}

###############################################################################
# Scenario B: default off - shared-socket workers must NOT drain a queue that
# a live sibling would serve; behaviour (and the immediate shutdown) is
# unchanged.
###############################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "made listen socket (default-off scenario)";

    my $evh = Feersum->new_instance();
    my $served = 0;
    $evh->request_handler(sub {
        my $r = shift;
        $served++;
        $r->send_response(200, ['Content-Type' => 'text/plain'], ["oops\n"]);
    });
    $evh->use_socket($socket);

    ok $evh->pause_accept, 'paused accept (default-off scenario)';
    my $client = queue_one_connection($port);
    ok $client, 'client connected while accept was paused';

    my $cv = AE::cv;
    my $guard_t = AE::timer 10 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') };
    $evh->graceful_shutdown(sub { $cv->send('done') });
    is $cv->recv, 'done', 'graceful_shutdown completed immediately';

    my ($buf, $err) = drain_client($client);
    is $served, 0, 'queued connection was not served with the flag off';
    close $client;
}
