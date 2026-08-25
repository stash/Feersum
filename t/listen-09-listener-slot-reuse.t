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

plan tests => 4;

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
