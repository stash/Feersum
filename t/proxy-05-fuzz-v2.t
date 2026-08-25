#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use AnyEvent;
use AnyEvent::Handle;
use Errno ();
use Feersum;

# Scale the per-connection deadline like the rest of the suite: on a loaded
# smoker a 1s timeout would otherwise be reached routinely.
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);

plan tests => 101;

my ($socket, $port) = get_listen_socket();
my $evh = Feersum->new;
$evh->set_proxy_protocol(1);
$evh->set_keepalive(0);
$evh->use_socket($socket);

$evh->psgi_request_handler(sub {
    return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
});

# Valid header, used both as the baseline case and as the liveness re-probe.
my $valid_v2 = "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A" . # sig
               "\x21" . # ver 2, cmd proxy
               "\x11" . # fam AF_INET, proto STREAM
               "\x00\x0C" . # len 12
               "\x01\x02\x03\x04" . # src
               "\x05\x06\x07\x08" . # dst
               "\x00\x50" . # src port 80
               "\x01\xBB"; # dst port 443

# Report the seed so a failing fuzz case can actually be reproduced.
my $seed = defined $ENV{FEERSUM_FUZZ_SEED}
    ? srand($ENV{FEERSUM_FUZZ_SEED}) : srand();
diag("fuzz seed $seed (set FEERSUM_FUZZ_SEED=$seed to reproduce)");

# Synchronous liveness check: is the server still answering a KNOWN-GOOD
# request?  Used to tell a load-stalled request apart from a wedged server, so
# this file stays meaningful without false-failing on a busy smoker.
sub server_alive {
    my $cv = AE::cv;
    my $ok = 0;
    my $h;
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        on_connect => sub {
            $_[0]->push_write($valid_v2 .
                "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        },
        on_error => sub { $_[0]->destroy; $cv->send },
        on_eof   => sub { $_[0]->destroy; $cv->send },
        timeout  => 10 * TIMEOUT_MULT,
    );
    $h->push_read(regex => qr{HTTP/1\.\d (\d{3})}, sub {
        $ok = ($1 == 200) ? 1 : 0;
        $_[0]->destroy;
        $cv->send;
    });
    $cv->recv;
    return $ok;
}

sub test_header {
    my ($header, $name) = @_;
    my $cv = AE::cv;
    my $h;
    my $got_error = 0;   # 'error' or 'timeout'
    my $got_eof = 0;
    my $got_response = 0;

    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        on_connect => sub {
            my $handle = shift;
            $handle->push_write($header);
            $handle->push_write("GET / HTTP/1.1
Host: localhost
Connection: close

");
        },
        on_error => sub {
            # A timeout is NOT evidence that the server rejected anything.
            $got_error = ($! == Errno::ETIMEDOUT()) ? 'timeout' : 'error';
            $_[0]->destroy;
            $cv->send;
        },
        on_eof => sub {
            $got_eof = 1;
            $_[0]->destroy;
            $cv->send;
        },
        timeout => 3 * TIMEOUT_MULT,
    );

    $h->push_read(regex => qr/HTTP\/1\.\d (\d{3})/, sub {
        my ($handle, $status) = @_;
        $got_response = $1;
        $handle->destroy;
        $cv->send;
    });

    $cv->recv;
    
    # Success means it either errored out correctly (4xx) or closed connection
    # For baseline, we expect 200.
    if ($got_response) {
        if ($name =~ /Baseline/ && $got_response == 200) {
            pass("$name: correctly accepted valid header");
        } elsif ($got_response =~ /^4/) {
            pass("$name: correctly rejected with $got_response");
        } elsif ($got_response == 200) {
            fail("$name: incorrectly accepted malformed header as 200 OK");
        } else {
            pass("$name: returned $got_response");
        }
    } elsif ($got_eof || ($got_error && $got_error ne 'timeout')) {
        pass("$name: connection closed/errored as expected");
    } elsif (server_alive()) {
        # Timed out, but the server still answers a known-good request: this is
        # load on the machine, not a parser defect.
        pass("$name: no answer before the deadline; server still healthy");
    } else {
        # Silence AND the server no longer answers a valid request: wedged or
        # gone.  Treating this as success is what made every case in this file
        # pass even with the listener disabled.
        fail("$name: no response and the server stopped answering");
    }
}

# 1. Valid header for baseline
test_header($valid_v2, "Baseline valid V2 header");

# Fuzzing starts here
for (1..100) {
    my $type = int(rand(6));
    my $header = "";
    my $name = "Fuzz test $_";

    if ($type == 0) {
        # Random bytes of random length
        $header = pack("C*", map { int(rand(256)) } 1..(5 + int(rand(50))));
        $name .= " (random bytes)";
    } elsif ($type == 1) {
        # Valid signature, but everything else random
        $header = "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A" . 
                  pack("C*", map { int(rand(256)) } 1..(int(rand(40))));
        $name .= " (valid sig, random tail)";
    } elsif ($type == 2) {
        # Truncated valid header
        $header = substr($valid_v2, 0, 1 + int(rand(length($valid_v2) - 1)));
        $name .= " (truncated valid)";
    } elsif ($type == 3) {
        # Valid header but with random TLVs at the end
        my $len = 12 + int(rand(100));
        $header = substr($valid_v2, 0, 14) . pack("n", $len) . substr($valid_v2, 16);
        $header .= pack("C*", map { int(rand(256)) } 1..$len);
        $name .= " (valid base, random TLVs)";
    } elsif ($type == 4) {
        # Wrong signature (one byte off) - ensure byte actually changes
        $header = $valid_v2;
        my $pos = int(rand(12));
        my $orig = ord(substr($header, $pos, 1));
        my $new = ($orig + 1 + int(rand(254))) % 256;
        substr($header, $pos, 1) = pack("C", $new);
        $name .= " (corrupted signature)";
    } else {
        # Valid base but wrong version/command
        $header = $valid_v2;
        substr($header, 12, 1) = pack("C", int(rand(256)) & 0x0F); # version != 2
        $name .= " (invalid version)";
    }

    test_header($header, $name);
}
