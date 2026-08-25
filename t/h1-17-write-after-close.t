#!/usr/bin/env perl
use warnings;
use strict;
use Test::More tests => 16;
use IO::Socket::INET;

use lib 't'; use Utils;

use_ok('Feersum');

my ($socket, $port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();

my $test_case = '';
my $caught_error = '';
my $writer_ref;

$evh->request_handler(sub {
    my $r = shift;

    if ($test_case eq 'write_after_close') {
        my $w = $r->start_streaming("200 OK", [
            'Content-Type' => 'text/plain',
        ]);
        $w->write("First write\n");
        $w->close();
        eval { $w->write("After close\n"); };
        $caught_error = $@ if $@;
    }
    elsif ($test_case eq 'write_array_after_close') {
        my $w = $r->start_streaming("200 OK", [
            'Content-Type' => 'text/plain',
        ]);
        $w->write("First write\n");
        $w->close();
        eval { $w->write_array(["After", " close\n"]); };
        $caught_error = $@ if $@;
    }
    elsif ($test_case eq 'close_twice') {
        my $w = $r->start_streaming("200 OK", [
            'Content-Type' => 'text/plain',
        ]);
        $w->write("Content\n");
        $w->close();
        eval { $w->close(); };
        $caught_error = $@ if $@;
    }
    elsif ($test_case eq 'sendfile_after_close') {
        my $w = $r->start_streaming("200 OK", [
            'Content-Type' => 'text/plain',
        ]);
        $w->close();
        eval {
            open my $fh, '<', $0 or die "open: $!";
            $w->sendfile($fh, 0, 10);
            close $fh;
        };
        $caught_error = $@ if $@;
    }
    elsif ($test_case eq 'stash_writer') {
        my $w = $r->start_streaming("200 OK", [
            'Content-Type' => 'text/plain',
        ]);
        $w->write("Immediate\n");
        $writer_ref = $w;  # Stash for later use
    }
    else {
        $r->send_response(200, ['Content-Type' => 'text/plain'], "OK\n");
    }
});

$evh->use_socket($socket);

# Helper to run a test request
sub run_request {
    my $client = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port",
        Proto    => 'tcp',
        Timeout  => 3,
    );
    return undef unless $client;

    print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    my $iterations = 0;
    while ($iterations++ < 50) {
        EV::run(EV::RUN_NOWAIT());
        select(undef, undef, undef, 0.01);
    }

    my $response = '';
    $client->blocking(0);
    my $buf;
    while (sysread($client, $buf, 8192)) {
        $response .= $buf;
        EV::run(EV::RUN_NOWAIT());
    }
    close $client;

    return $response;
}

#######################################################################
# Test 1: write() after close()
#######################################################################

{
    $test_case = 'write_after_close';
    $caught_error = '';

    my $response = run_request();
    ok length($response) > 0, "write_after_close: got response";
    like $response, qr/First write/, "write_after_close: initial write succeeded";
    like $caught_error, qr/closed|shutdown|finished|invalid/i,
        "write_after_close: write after close caught error: $caught_error";
}

#######################################################################
# Test 2: write_array() after close()
#######################################################################

{
    $test_case = 'write_array_after_close';
    $caught_error = '';

    my $response = run_request();
    ok length($response) > 0, "write_array_after_close: got response";
    like $caught_error, qr/closed|shutdown|finished|invalid/i,
        "write_array_after_close: caught error: $caught_error";
}

#######################################################################
# Test 3: close() twice
#######################################################################

{
    $test_case = 'close_twice';
    $caught_error = '';

    my $response = run_request();
    ok length($response) > 0, "close_twice: got response";
    # "no error OR a matching error" could not fail.  Verified behaviour: the
    # second close croaks "Operation not allowed: Handle is closed."
    like $caught_error, qr/Handle is closed/,
        "close_twice: second close is rejected, not silently ignored";
}

#######################################################################
# Test 4: sendfile() after close()
#######################################################################

SKIP: {
    skip "sendfile only on Linux", 2 unless $^O eq 'linux';

    $test_case = 'sendfile_after_close';
    $caught_error = '';

    my $response = run_request();
    ok length($response) > 0, "sendfile_after_close: got response";
    like $caught_error, qr/closed|shutdown|finished|invalid/i,
        "sendfile_after_close: caught error: $caught_error";
}

#######################################################################
# Test 5: a writer stashed past the end of the handler is still usable (the
# core streaming contract).
#######################################################################

{
    $test_case = 'stash_writer';
    $caught_error = '';
    $writer_ref = undef;

    my $client = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Proto => 'tcp', Timeout => 3,
    );
    ok $client, "stash_writer: connected";

    print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    # Let the handler run and return, leaving the response open.
    for (1 .. 50) { EV::run(EV::RUN_NOWAIT()); select undef, undef, undef, 0.01 }

    ok $writer_ref, "stash_writer: handler stashed the writer and returned";

    # Now write from outside the handler entirely, then finish the response.
    my $late_ok = eval { $writer_ref->write("Later\n"); $writer_ref->close; 1 };
    my $late_err = $@;
    ok $late_ok, "stash_writer: writing after the handler returned succeeds"
        or diag $late_err;

    for (1 .. 50) { EV::run(EV::RUN_NOWAIT()); select undef, undef, undef, 0.01 }

    my $response = '';
    $client->blocking(0);
    my $buf;
    while (sysread($client, $buf, 8192)) {
        $response .= $buf;
        EV::run(EV::RUN_NOWAIT());
    }
    close $client;

    like $response, qr/Immediate/, "stash_writer: in-handler chunk delivered";
    like $response, qr/Later/,     "stash_writer: post-handler chunk delivered";
    $writer_ref = undef;
}
