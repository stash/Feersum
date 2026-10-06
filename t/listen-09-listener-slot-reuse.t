#!perl
# Registering a descriptor that is already in the listener table (use_socket
# twice with one socket) must not add a second slot, or shutdown closes the
# descriptor twice and the second close lands on whatever recycled the number.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

plan tests => 6;

my $dir = tempdir(CLEANUP => 1);
my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', "$dir/srv.out";
    open STDERR, '>', "$dir/srv.err";
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->use_socket($sock);      # the same descriptor a second time
    my $shutdown;
    $f->psgi_request_handler(sub {
        # Drive the shutdown from the request itself.  Reaping the server on a
        # wall-clock guess raced the teardown and killed it first, so the
        # listener close - the whole point - never ran and the test passed
        # against the bug.
        $shutdown ||= EV::timer 0.2 * TIMEOUT_MULT, 0, sub {
            $f->graceful_shutdown(sub { POSIX::_exit(0) });
        };
        [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });
    my $life_timer = EV::timer(30 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(1);
}
close $sock;
select undef, undef, undef, 0.8 * TIMEOUT_MULT;

my $served = 0;
{
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 10 * TIMEOUT_MULT);
    ok $s, 'connected to the doubly-registered listener';
    if ($s) {
        syswrite $s, "GET / HTTP/1.0\r\n\r\n";
        my $raw = '';
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 10 * TIMEOUT_MULT;
            while (1) { my $n = sysread $s, my $z, 4096; last if !$n; $raw .= $z }
            alarm 0;
            1;
        };
        alarm 0;
        close $s;
        $served = $raw =~ m{^HTTP/1\.[01] 200} ? 1 : 0;
    }
}
ok $served, 'registering one socket twice still leaves a working listener';

# Wait for the server to shut itself down, so the listener teardown has run
# before its stderr is read.
{
    my $deadline = time + 20 * TIMEOUT_MULT;
    my $reaped = 0;
    while (time < $deadline) {
        if (waitpid($server, POSIX::WNOHANG) == $server) { $reaped = 1; last }
        select undef, undef, undef, 0.05;
    }
    if (!$reaped) { reap_server($server) }
}

my $err = '';
if (open my $h, '<', "$dir/srv.err") { local $/; $err = <$h> // ''; close $h }
unlike $err, qr/close\(listen fd\).*Bad file descriptor/,
    'the listen descriptor is closed once, not once per slot'
    or diag "server stderr:\n$err";

# re-registering one listener must not move another's SERVER_PORT identity
{
    my ($sock_a, $port_a) = get_listen_socket();
    my ($sock_b, $port_b) = get_listen_socket();
    my $want_b = (eval { $sock_b->sockhost() } || 'localhost') . "|$port_b";
    my $server2 = fork();
    die "fork: $!" unless defined $server2;
    if (!$server2) {
        $SIG{QUIT} = 'DEFAULT';
        my $f = Feersum->new_instance();
        $f->use_socket($sock_a);
        $f->use_socket($sock_b);
        $f->use_socket($sock_a); # re-register the first descriptor
        $f->psgi_request_handler(sub {
            my $env = shift;
            my $body = "$env->{SERVER_NAME}|$env->{SERVER_PORT}";
            [200, ['Content-Type' => 'text/plain',
                   'Content-Length' => length($body)], [$body]];
        });
        my $life = EV::timer(30 * TIMEOUT_MULT, 0, sub { POSIX::_exit(2) });
        EV::run();
        POSIX::_exit(3);
    }
    close $sock_a;
    close $sock_b;
    select undef, undef, undef, 0.8 * TIMEOUT_MULT;

    my $body = '';
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port_b",
                                  Timeout => 10 * TIMEOUT_MULT);
    ok $s, 'connected to the second listener';
    if ($s) {
        syswrite $s, "GET / HTTP/1.0\r\nHost: x\r\n\r\n";
        my $raw = '';
        while (1) { my $n = sysread $s, my $z, 4096; last if !$n; $raw .= $z }
        close $s;
        ($body) = $raw =~ /\r\n\r\n(.*)$/s;
    }
    is $body, $want_b,
        're-registering listener A leaves listener B identity alone';
    reap_server($server2);
}
