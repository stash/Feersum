#!perl
# A psgix.io takeover handle shares Feersum's descriptor.  Once given away,
# Feersum must not close that number itself: the app may already have closed
# it and the kernel reused it for an unrelated live connection.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 8;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use Feersum;

my ($sock, $port) = get_listen_socket();
ok $sock, "got listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    our $held;
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->header_timeout(30 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $p = $env->{PATH_INFO} // q{};
        if ($p eq '/grab') {
            return sub {
                my $respond = shift;             # never called: legal takeover
                my $io = $env->{'psgix.io'};     # reading the VALUE takes it
                if ($io) {
                    $held = $io;
                    syswrite $io,
                        "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\ngrabbed";
                }
            };
        }
        if ($p eq '/drop') {                     # app closes its own handle
            close $held if $held;
            return [200, ['Content-Type' => 'text/plain'], ['dropped']];
        }
        if ($p eq '/forget') {                   # glob released -> conn DESTROY
            $held = undef;
            return [200, ['Content-Type' => 'text/plain'], ['forgot']];
        }
        return [200, ['Content-Type' => 'text/plain'], ['hi']];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

sub conn {
    return IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                 Timeout => 8 * TIMEOUT_MULT);
}

sub ask {
    my ($s, $path) = @_;
    return 'NOSOCK' unless $s;
    syswrite($s, "GET $path HTTP/1.1\r\nHost: x\r\n\r\n") or return 'WRITEFAIL';
    my $buf = q{};
    my $deadline = time + 10 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $rin = q{};
        vec($rin, fileno($s), 1) = 1;
        next unless select $rin, undef, undef, 0.5;
        my $g = sysread $s, my $z, 65536;
        return 'EOF' if defined $g && $g == 0;
        last if !defined $g;
        $buf .= $z;
        last if $buf =~ /\r\n\r\n/;
    }
    my ($st) = $buf =~ m{^HTTP/1\.\d\ (\d{3})}x;
    my ($bd) = $buf =~ /\r\n\r\n(.*)\z/s;
    return ($st // '?') . q{ } . ($bd // q{});
}

my $sanity = conn();
like ask($sanity, '/hello'), qr/^200/, 'server answers before the takeover';

my $A = conn();
like ask($A, '/grab'), qr/^200 grabbed/, 'conn A: psgix.io taken by the app';

my $c = conn();
like ask($c, '/drop'), qr/^200 dropped/, 'app closed its own psgix.io handle';
close $c;

# The next accept gets the lowest free descriptor, which is the one the app
# just closed, so conn B is now sitting on conn A's old fd number.
my $B = conn();
like ask($B, '/hello'), qr/^200/, 'conn B is healthy on the recycled descriptor';

my $d = conn();
like ask($d, '/forget'), qr/^200 forgot/, 'app released the handle: conn A DESTROY runs';
close $d;

like ask($B, '/hello'), qr/^200/,
    'conn B SURVIVES conn A destruction (no cross-connection close)';

my $e = conn();
like ask($e, '/hello'), qr/^200/, 'server still serving afterwards';

close $_ for grep { $_ } $sanity, $A, $B, $e;
reap_server($server);
