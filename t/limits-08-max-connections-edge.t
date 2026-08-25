#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;
use IO::Socket::INET;

# max_connections boundaries: exactly at the limit, over it (rejected), and
# adjusted while connections are open.

BEGIN {
    plan skip_all => 'not applicable on win32'
        if $^O eq 'MSWin32';
}

plan tests => 13;

my ($socket, $port) = get_listen_socket();
ok $socket, 'made listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->max_connections(3);  # Set low limit for testing
$feer->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"ok");
});

# Test 1: Open connections up to limit
{
    my @sockets;
    my $cv = AE::cv;

    # Open 3 connections (at limit)
    for my $i (1..3) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => 'localhost',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 2,
        );
        if ($sock) {
            push @sockets, $sock;
        }
    }

    is(scalar(@sockets), 3, 'Opened 3 connections (at limit)');

    # Small delay to let connections be accepted
    my $timer = AE::timer 0.1, 0, sub { $cv->send };
    $cv->recv;

    # Try to open 4th connection - should be rejected or queued
    my $sock4 = IO::Socket::INET->new(
        PeerAddr => 'localhost',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );

    # Connection may succeed at TCP level but be closed by server
    if ($sock4) {
        # Try to send request - may get connection closed
        $sock4->print("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
        my $resp = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout" };
            alarm(1);
            $sock4->recv($resp, 1024);
            alarm(0);
        };
        # Past the limit the 4th connection must NOT be served a normal
        # response; queued-then-closed or refused are both fine.  Both arms
        # used to be ok(1), so this could not fail even with the cap removed.
        unlike($resp, qr{^HTTP/1\.[01] 200},
               '4th connection not served while at max_connections');
        close($sock4);
    } else {
        ok(1, '4th connection rejected at TCP level');
    }

    # Close all sockets
    close($_) for @sockets;

    # Let event loop process the closes (active_conns decrements)
    my $drain = AE::cv;
    my $dt = AE::timer 1.0 * TIMEOUT_MULT, 0, sub { $drain->send };
    $drain->recv;
}

# Test 2: Verify connections work after limit is freed
# Retry a few times - on some OSes (FreeBSD) close events take longer to process
{
    my $response = '';
    my $attempts = 3;
    for my $attempt (1 .. $attempts) {
        my $cv = AE::cv;
        $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        $h->push_write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
        });

        my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;
        $h->destroy;

        last if $response =~ /HTTP\/1\.1 200/;

        # Wait before retry to let close events propagate
        $cv = AE::cv;
        my $delay = AE::timer 0.5 * TIMEOUT_MULT, 0, sub { $cv->send };
        $cv->recv;
    }

    like($response, qr/HTTP\/1\.1 200/, 'Connection works after limit freed');
}

# Test 3: max_connections(0) means unlimited
{
    $feer->max_connections(0);  # Unlimited

    my @sockets;

    # Open 10 connections
    for my $i (1..10) {
        my $sock = IO::Socket::INET->new(
            PeerAddr => 'localhost',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 2,
        );
        push @sockets, $sock if $sock;
    }

    cmp_ok(scalar(@sockets), '>=', 5, 'max_connections(0): opened many connections');

    close($_) for @sockets;
}

# Test 4: Verify active_conns metric
{
    my $active = $feer->active_conns();
    ok(defined $active, 'active_conns() returns value');
    cmp_ok($active, '>=', 0, 'active_conns() is non-negative');
}

# Test 5: Set max_connections back and verify enforcement
{
    $feer->max_connections(2);  # Very low limit

    my @handles;
    my $cv = AE::cv;
    my $connected = 0;
    my $errors = 0;

    # Try to open 5 connections rapidly
    for my $i (1..5) {
        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_connect => sub { $connected++; },
            on_error => sub { $errors++; },
            on_eof => sub { },
        );
        push @handles, $h;
    }

    # Wait briefly for connections
    my $timer = AE::timer 0.3, 0, sub { $cv->send };
    $cv->recv;

    # Should have at least some connected
    cmp_ok($connected, '>=', 2, 'max_connections(2): at least 2 connected');

    # Clean up
    $_->destroy for @handles;
}

# Test 6: max_connections getter
{
    $feer->max_connections(100);
    my $val = $feer->max_connections();
    is($val, 100, 'max_connections getter returns set value');
}

# Test 7: max_connections with keepalive
{
    $feer->max_connections(3);
    $feer->set_keepalive(1);

    my $cv = AE::cv;
    my @responses;

    # Send multiple requests on same connection
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $port],
        on_error => sub { $cv->send; },
        on_eof => sub { $cv->send; },
    );

    # Send 3 requests pipelined
    $h->push_write(
        "GET /1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
        "GET /2 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
        "GET /3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    );

    my $buffer = '';
    $h->on_read(sub {
        $buffer .= $h->rbuf;
        $h->rbuf = '';
        my $count = () = $buffer =~ /HTTP\/1\.1 200/g;
        $cv->send if $count >= 3;
    });

    my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    my $count = () = $buffer =~ /HTTP\/1\.1 200/g;
    is($count, 3, 'max_connections with keepalive: 3 responses on single conn');
}

# Test 8: Idle conn recycling at max_connections
{
    $feer->max_connections(2);
    $feer->set_keepalive(1);

    my $cv = AE::cv;
    my $done_count = 0;
    my @handles;

    # Open 2 keepalive connections, send requests, read responses
    for my $i (1..2) {
        $cv->begin;
        my $h;
        $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1', $port],
            on_error => sub { $cv->end },
            timeout => 5 * TIMEOUT_MULT,
        );
        # HTTP/1.1 default is keepalive
        $h->push_write("GET /$i HTTP/1.1\r\nHost: localhost\r\n\r\n");
        $h->push_read(regex => qr/\r\n\r\n/, sub {
            $_[0]->push_read(chunk => 2, sub {
                $done_count++;
                $cv->end;
            });
        });
        push @handles, $h;
    }

    my $guard = AE::timer 5 * TIMEOUT_MULT, 0, sub { $cv->croak("timeout") };
    eval { $cv->recv };
    is $done_count, 2, 'idle recycling: 2 keepalive conns got responses';

    # Let event loop process idle transitions
    $cv = AE::cv;
    my $pt = AE::timer 0.3, 0, sub { $cv->send };
    $cv->recv;

    # Silence errors on recycled handles
    for my $h (@handles) {
        $h->on_error(sub { $_[0]->destroy });
        $h->on_eof(sub { $_[0]->destroy });
        $h->on_read(sub {});
    }

    # 3rd connection should succeed via idle recycling
    $cv = AE::cv;
    my $resp3 = '';
    my $h3;
    $h3 = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        on_error => sub { $_[0]->destroy; $cv->send },
        on_eof => sub { $_[0]->destroy; $cv->send },
        timeout => 3 * TIMEOUT_MULT,
    );
    $h3->push_write("GET /3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h3->on_read(sub {
        $resp3 .= $_[0]->rbuf;
        $_[0]->rbuf = '';
    });

    $guard = AE::timer 5 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;

    like $resp3, qr/HTTP\/1\.1 200/, 'idle recycling: 3rd conn succeeded (idle recycled)';

    $_->destroy for grep { $_ } @handles;
}

pass "all max_connections edge tests completed";
