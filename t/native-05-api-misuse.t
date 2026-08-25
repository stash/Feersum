#!/usr/bin/env perl
# Test API misuse scenarios - calling methods in wrong order/state
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

#######################################################################
# Test 1: start_streaming() called twice
#######################################################################
{
    my $double_stream_error;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        eval { $r->start_streaming(200, ['Content-Type' => 'text/plain']) };
        $double_stream_error = $@;
        $w->write("ok");
        $w->close();
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/double-stream', sub { $cv->send };
    $cv->recv;

    ok $double_stream_error, 'start_streaming() twice throws error';
    like $double_stream_error, qr/already|respond|start/i, 'error mentions already started';
}

#######################################################################
# Test 2: send_response() after start_streaming()
#######################################################################
{
    my $send_after_stream_error;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        eval { $r->send_response(200, [], 'body') };
        $send_after_stream_error = $@;
        $w->write("ok");
        $w->close();
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/send-after-stream', sub { $cv->send };
    $cv->recv;

    ok $send_after_stream_error, 'send_response() after start_streaming() throws error';
    like $send_after_stream_error, qr/already|respond|start/i, 'error mentions already started';
}

#######################################################################
# Test 3: send_response() called twice
#######################################################################
{
    my $double_send_error;

    $feer->request_handler(sub {
        my $r = shift;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'first');
        eval { $r->send_response(200, [], 'second') };
        $double_send_error = $@;
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/double-send', sub { $cv->send };
    $cv->recv;

    ok $double_send_error, 'send_response() twice throws error';
    like $double_send_error, qr/already|respond|complet/i, 'error mentions already responded';
}

#######################################################################
# Test 4: write() with HASH ref (should error)
#######################################################################
{
    my $write_hash_error;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        # Try to write a HASH ref (invalid)
        eval { $w->write({foo => 'bar'}) };
        $write_hash_error = $@;
        $w->write("ok");
        $w->close();
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/write-hash', sub { $cv->send };
    $cv->recv;

    ok $write_hash_error, 'write() with HASH ref throws error';
    like $write_hash_error, qr/scalar/i, 'error mentions scalar requirement';
}

#######################################################################
# Test 5: write() outside streaming mode
#######################################################################
{
    my $captured_writer;
    my $write_outside_error;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $captured_writer = $w;
        $w->write("ok");
        $w->close();
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/capture-writer', sub { $cv->send };
    $cv->recv;

    # Try to write after close
    eval { $captured_writer->write("late") } if $captured_writer;
    $write_outside_error = $@;

    ok $write_outside_error, 'write() after close throws error';
}

#######################################################################
# Test 6: close() called twice (should not crash)
#######################################################################
{
    my $handler_completed = 0;

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write("data");
        $w->close();
        eval { $w->close() };  # Second close - should not crash
        $handler_completed = 1;
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/double-close', sub { $cv->send };
    $cv->recv;

    ok $handler_completed, 'double close() handled without crash';
}

#######################################################################
# Test 7: a Reader (psgi.input) rejects writer-only methods
#######################################################################
{
    my %r;
    $feer->request_handler(sub {
        my $req = shift;
        my $in = $req->env->{'psgi.input'};
        $r{is_reader}   = $in->isa('Feersum::Connection::Reader') ? 1 : 0;
        $r{write}       = (eval { $in->write("x"); 1 }) ? '' : $@;
        $r{write_array} = (eval { $in->write_array(["x"]); 1 }) ? '' : $@;
        $r{sendfile}    = (eval { $in->sendfile(\*STDIN); 1 }) ? '' : $@;
        $req->send_response(200, ['Content-Type' => 'text/plain'], ['ok']);
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/reader-guards', sub { $cv->send };
    $cv->recv;

    ok $r{is_reader}, 'psgi.input is a Feersum::Connection::Reader';
    like $r{write},       qr/read-only handle/, 'Reader->write croaks';
    like $r{write_array}, qr/read-only handle/, 'Reader->write_array croaks';
    like $r{sendfile},    qr/read-only handle/, 'Reader->sendfile croaks';
}

#######################################################################
# return_from_io() without a preceding io()/psgix.io.  It used to accept any
# filehandle and silently reset the responding/receiving state, freeing the
# request mid-flight; only a missing/undef argument was rejected.
#######################################################################
{
    my ($no_io_err, $undef_err);

    $feer->request_handler(sub {
        my $r = shift;
        open my $fh, '<', '/dev/null' or die "open /dev/null: $!";
        eval { $r->return_from_io($fh) };
        $no_io_err = $@;
        eval { $r->return_from_io(undef) };
        $undef_err = $@;
        $r->send_response(200, ['Content-Type' => 'text/plain'], ['ok']);
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/no-io', sub { $cv->send };
    $cv->recv;

    like $no_io_err, qr/without a preceding io/,
        'return_from_io() without io() croaks';
    like $undef_err, qr/without a preceding io|requires a filehandle/,
        'return_from_io(undef) without io() croaks';
}

#######################################################################
# The writer is not a glob: `fileno $w` dies, so the documented "keep the
# writer alive" idiom must key on 0+$w.
#######################################################################
{
    my ($builtin_err, $addr_key, $method_fd);

    $feer->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        eval { my $x = fileno $w; 1 } or $builtin_err = $@;
        $addr_key  = eval { 0 + $w };
        $method_fd = eval { $w->fileno };
        $w->write('ok');
        $w->close;
    });

    my $cv = AE::cv;
    my $h = simple_client GET => '/writer-key', sub { $cv->send };
    $cv->recv;

    like $builtin_err, qr/GLOB/i, 'CORE::fileno on a writer dies (documented idiom must not use it)';
    ok $addr_key, '0+$w yields a usable hash key';
    ok defined $method_fd && $method_fd >= 0, '$w->fileno returns the descriptor';
}

done_testing;
