#!/usr/bin/env perl
use strict;
use warnings;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use blib;
use Test::More;

# Check if IPv6 is available and can bind at runtime
my $ipv6_bind_works;
eval {
    require Socket;
    Socket->import(qw/AF_INET6 SOCK_STREAM inet_pton pack_sockaddr_in6/);
    # Try to actually use inet_pton with an IPv6 address
    my $addr = inet_pton(Socket::AF_INET6(), '::1');
    if (defined $addr) {
        # Try to actually bind to ::1 to see if it works
        my $sock;
        socket($sock, Socket::AF_INET6(), Socket::SOCK_STREAM(), 0) or die "socket: $!";
        bind($sock, Socket::pack_sockaddr_in6(0, $addr)) or die "bind: $!";
        close($sock);
        $ipv6_bind_works = 1;
    }
};

plan tests => 21;  # 2 use_ok + 5 parse/validate + 6 IPv6 bind (run or skipped) + 2 vendorless Socket + 6 integration
note "IPv6 bind test: " . ($ipv6_bind_works ? "available" : "not available");

use_ok('Feersum::Runner');
use_ok('Feersum');

# Drive Feersum::Runner::_create_socket for real.  These tests used to assert
# against an inlined COPY of Runner's regexes, so Runner could have been
# deleted outright and they would still pass - and the copy had already drifted
# (it lacked the ambiguous-bare-IPv6 guard).
#######################################################################

my $runner = Feersum::Runner->new(listen => ['localhost:0'], quiet => 1);

# Port validation is address-family independent and always reachable.
{
    my $s = eval { $runner->_create_socket('127.0.0.1:0', 0) };
    ok $s, 'IPv4 host:port binds' or diag $@;
    close $s if $s;

    eval { $runner->_create_socket('127.0.0.1:99999', 0) };
    like $@, qr/invalid port '99999'/, 'port above 65535 is rejected';

    eval { $runner->_create_socket('127.0.0.1:http', 0) };
    like $@, qr/invalid port/, 'non-numeric port is rejected';
}

# A bare IPv6 address whose tail looks like a port is ambiguous and must be
# rejected on BOTH the reuseport and non-reuseport paths - the guard used to
# live only in the reuseport branch.
for my $reuseport (0, 1) {
    eval { $runner->_create_socket('2001:db8::1:8080', $reuseport) };
    like $@, qr/ambiguous IPv6 address/,
        "ambiguous bare IPv6 rejected (reuseport=$reuseport)";
}

SKIP: {
    skip "IPv6 bind to ::1 not available on this system", 6
        unless $ipv6_bind_works;

    # Bracketed notation, with and without a port, on both paths.  Without the
    # fix the non-reuseport path handed '[::1]:0' straight to IO::Socket::INET
    # (IPv4-only) and died with "invalid port ':1]'".
    for my $reuseport (0, 1) {
        for my $addr ('[::1]:0', '[::1]') {
            my $s = eval { $runner->_create_socket($addr, $reuseport) };
            ok $s, "Runner binds IPv6 '$addr' (reuseport=$reuseport)"
                or diag $@;
            close $s if $s;
        }
    }
    # The bound socket really is AF_INET6, not a v4 fallback.
    my $s6 = eval { $runner->_create_socket('[::1]:0', 0) };
    SKIP: {
        skip "could not bind [::1]:0", 2 unless $s6;
        my $sa = getsockname($s6);
        is Socket::sockaddr_family($sa), Socket::AF_INET6(),
            'listener is a real AF_INET6 socket';
        my ($p) = Socket::unpack_sockaddr_in6($sa);
        cmp_ok $p, '>', 0, 'ephemeral IPv6 port was assigned';
        close $s6;
    }
}

#######################################################################
# Socket exports SO_REUSEPORT/AF_INET6 even where its build found no macro for
# them and croaks only when the constant is CALLED, so trusting import() killed
# every reuseport and IPv6 path on such a box (Debian wheezy).
{
    my $prog = <<'PROG';
BEGIN {
    require Socket;
    no strict 'refs'; no warnings 'redefine';
    # "Constant subroutine redefined" is a default-on warning on some perls
    # and reached stdout through 2>&1, breaking the anchored match below.
    local $SIG{__WARN__} = sub {};
    for my $n (split /,/, $ARGV[0]) {
        *{"Socket::$n"} = sub () {
            require Carp;
            Carp::croak("Your vendor has not defined Socket macro $n, used");
        };
    }
}
use Feersum::Runner ();
my $r = Feersum::Runner->new(listen => ['localhost:0'], quiet => 1);
my $s = eval { $r->_create_socket($ARGV[1], $ARGV[2]) };
print $s ? "bound\n" : "died: $@";
close $s if $s;
PROG
    my ($fh, $file) = do { require File::Temp; File::Temp::tempfile(UNLINK => 1) };
    print $fh $prog;
    close $fh;

    my $rp = `$^X -Mblib $file SO_REUSEPORT 127.0.0.1:0 1 2>/dev/null`;
    like $rp, qr/^bound$/m,
        'unusable SO_REUSEPORT falls back instead of croaking through _create_socket'
        or diag $rp;

    my $v6 = `$^X -Mblib $file AF_INET6 [::1]:0 0 2>/dev/null`;
    like $v6, qr/IPv6 not supported on this system/,
        'unusable AF_INET6 croaks with our message, not the vendor one'
        or diag $v6;
}

#######################################################################
#######################################################################
# Test actual IPv6 socket creation and HTTP request
#######################################################################

SKIP: {
    if (!$ipv6_bind_works) {
        skip "IPv6 bind to ::1 not available on this system", 6;
        last SKIP;  # Explicitly exit block for older/unusual Perl builds
    }

    note "IPv6 support detected - running end-to-end test";

    # Create IPv6 socket manually (simulating what Runner does in reuseport mode)
    require Socket;
    Socket->import(qw/AF_INET6 SOCK_STREAM SOMAXCONN inet_pton pack_sockaddr_in6 unpack_sockaddr_in6/);
    require IO::Handle;

    my $sock;
    socket($sock, Socket::AF_INET6(), Socket::SOCK_STREAM(), 0) or die "socket: $!";
    setsockopt($sock, Socket::SOL_SOCKET(), Socket::SO_REUSEADDR(), pack("i", 1));
    my $addr = Socket::inet_pton(Socket::AF_INET6(), '::1');
    bind($sock, Socket::pack_sockaddr_in6(0, $addr)) or die "bind: $!";
    listen($sock, Socket::SOMAXCONN()) or die "listen: $!";
    bless $sock, 'IO::Handle';
    $sock->blocking(0);

    # Get the assigned port
    my $sockaddr = getsockname($sock);
    my ($port) = Socket::unpack_sockaddr_in6($sockaddr);
    ok $port > 0, "IPv6 socket bound to port $port";

    # Set up Feersum with the IPv6 socket
    my $feer = Feersum->new();
    $feer->use_socket($sock);

    my $request_received = 0;
    my $remote_addr;

    $feer->request_handler(sub {
        my $r = shift;
        $request_received = 1;
        $remote_addr = $r->remote_address;
        $r->send_response(200, ['Content-Type' => 'text/plain'], 'IPv6 OK');
    });

    # Make request using IPv6
    require AnyEvent;
    require AnyEvent::Socket;
    require AnyEvent::Handle;

    my $cv = AnyEvent->condvar;
    my $response_body = '';

    AnyEvent::Socket::tcp_connect('::1', $port, sub {
        my ($fh) = @_;
        if (!$fh) {
            $cv->croak("Failed to connect: $!");
            return;
        }

        my $h = AnyEvent::Handle->new(
            fh => $fh,
            on_error => sub { $cv->croak("Handle error: $_[2]") },
        );

        $h->push_write("GET / HTTP/1.1\r\nHost: [::1]:$port\r\nConnection: close\r\n\r\n");

        $h->push_read(regex => qr/\r\n\r\n/, sub {
            my $headers = $_[1];
            ok $headers =~ /200 OK/, 'IPv6: got 200 response';

            $h->on_read(sub {
                $response_body .= $h->rbuf;
                $h->rbuf = '';
            });
            $h->on_eof(sub { $cv->send });
        });
    });

    # Failure bound only - a healthy loopback request answers in milliseconds.
    # 3 * MULT lost this section on a single-core armv6l smoker whose suite ran
    # 4357s at roughly a third of the CPU.
    my $timeout = AnyEvent->timer(after => 30 * TIMEOUT_MULT, cb => sub { $cv->croak("timeout") });
    eval { $cv->recv };
    my $err = $@;

    ok !$err, 'IPv6: no error during request' or diag $err;
    ok $request_received, 'IPv6: request handler was called';
    is $response_body, 'IPv6 OK', 'IPv6: got correct response body';
    like $remote_addr, qr/^::1$|^::ffff:127/, 'IPv6: remote_address is IPv6 localhost';

    # Cleanup
    $feer->unlisten();
    close($sock);
}
