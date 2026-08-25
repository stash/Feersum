#!perl
# Test slow-client/Slowloris-style attack protection
# Verifies that read timeouts trigger correctly when clients send data
# very slowly (byte-by-byte with delays)
use warnings;
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use constant HARDER => $ENV{RELEASE_TESTING} ? 5 : 1;
use constant SLOW_CLIENTS => HARDER * 2;
use constant GOOD_CLIENTS => HARDER * 2;
use constant CHAR_DELAY   => 0.9 * TIMEOUT_MULT;
# Test plan: 5 fixed + 2 per slowloris (connected + closed) + 3 per good (connected + 200 + body) + 1 final
use Test::More tests => 7 + 2*SLOW_CLIENTS + 3*GOOD_CLIENTS;
use Test::Fatal;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
is exception { $evh->use_socket($socket) }, undef, "bound to socket";

# Set timeout for testing - scaled for slow machines
# This is the max time allowed for complete request headers to arrive
# Base is 3s for slow-machine tolerance
my @slowloris_lifetimes;
my $read_timeout = 3.0 * TIMEOUT_MULT;
$evh->read_timeout($read_timeout);
is $evh->read_timeout, $read_timeout, "timeout set to $read_timeout second(s)";

$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    $r->send_response(200, ["Content-Type" => "text/plain"], "OK");
});

my $cv = AE::cv;

# Slowloris-style client: sends headers byte-by-byte with delays
# This should trigger a read timeout
sub slowloris_client {
    my $n = shift;
    $cv->begin;

    my $started_at = AE::now();
    my $ended_at;
    push @slowloris_lifetimes, \$ended_at;

    my $h; $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        on_connect => sub {
            my $handle = shift;
            pass "(slowloris $n) connected";

            # Send request very slowly - one char every 0.3*MULT seconds
            # With read_timeout, this should timeout before completing
            my $request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
            my @chars = split //, $request;
            my $idx = 0;
            # Delay between chars for slow-machine tolerance
            # Total time (chars * delay) must exceed read_timeout to trigger slowloris behavior
            my $char_delay = CHAR_DELAY;

            my $send_next; $send_next = sub {
                return if !$h;  # connection closed
                if ($idx < @chars) {
                    $h->push_write($chars[$idx++]);
                    my $t; $t = AE::timer $char_delay, 0, sub {
                        $send_next->();
                        undef $t;
                    };
                }
            };
            $send_next->();
        },
        # These fired unconditionally, so the section passed whether the
        # slowloris protection reaped the connection or the attack simply ran
        # to completion.  Record WHEN the connection ended; the deadline check
        # after $cv->recv is what actually distinguishes the two.
        on_error => sub {
            my ($handle, $fatal, $msg) = @_;
            $ended_at = AE::now() - $started_at;
            pass "(slowloris $n) connection ended (timeout or error)";
            $cv->end;
            undef $h;
        },
        on_eof => sub {
            $ended_at = AE::now() - $started_at;
            pass "(slowloris $n) server closed connection";
            $cv->end;
            undef $h;
        },
        on_read => sub {
            my $handle = shift;
            my $data = $handle->{rbuf};
            $handle->{rbuf} = '';
            # We might get a 408 response before disconnect (informational, not a counted test)
            if ($data =~ /408/) {
                note "(slowloris $n) got 408 timeout response";
            }
        },
        timeout => 5 * TIMEOUT_MULT,
    );
}

# Good client that completes quickly
sub good_client {
    my $n = "(good $_[0])";
    $cv->begin;
    # Tripled random delay (1.5s max) for slow-machine tolerance
    my $ot; $ot = AE::timer rand(1.5 * TIMEOUT_MULT), 0, sub {
        my $h; $h = simple_client GET => "/",
            name => $n,
            headers => {},
            timeout => 10 * TIMEOUT_MULT,
        sub {
            my ($body, $headers) = @_;
            is $headers->{Status}, 200, "$n got 200";
            is $body, "OK", "$n got body";
            $cv->end;
            undef $h;
        };
        undef $ot;
    };
}

# Guard timer to match scaled timing values
my $guard; $guard = AE::timer 35 * TIMEOUT_MULT, 0, sub {
    Test::More::fail("TEST TIMEOUT - took too long"); $cv->send;
};

$cv->begin;

# Start slow clients first
slowloris_client($_) for (1 .. SLOW_CLIENTS);

# Start good clients - they should complete even with slow clients present
good_client($_) for (1 .. GOOD_CLIENTS);

$cv->end;

is exception { $cv->recv }, undef, "all clients handled correctly";

# The server must have cut the slow clients off, not merely watched them finish.
# It is header_timeout that cuts: read_timeout is reset by every byte, and this
# client sends one every CHAR_DELAY < read_timeout, so it would never expire.
{
    my @lifetimes = map { $$_ } @slowloris_lifetimes;
    my $ceiling = 1.6 * $evh->header_timeout;
    my @survivors = grep { !defined($_) || $_ > $ceiling } @lifetimes;
    is scalar(@survivors), 0,
        "slowloris connections were cut off near header_timeout, not left to run"
        or diag "lifetimes: " . join(', ',
            map { defined $_ ? sprintf('%.1fs', $_) : 'never ended' } @lifetimes)
         . " (ceiling ${ceiling}s, header_timeout " . $evh->header_timeout . "s)";
}
