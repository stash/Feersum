#!perl
# Empty Host fields must be rejected (RFC 9112 5.5) and an empty absolute-form
# authority must not erase a valid Host header.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);

my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_keepalive(1);
    $f->psgi_request_handler(sub {
        my $env = shift;
        return [200, ['Content-Type' => 'text/plain'],
            ["host=" . ($env->{HTTP_HOST} // 'missing')]];
    });
    my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

sub exchange {
    my ($request) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Timeout => 5 * TMULT) or die "connect: $!";
    my $response = '';
    eval {
        local $SIG{ALRM} = sub { die "request timeout\n" };
        alarm 5 * TMULT;
        my $off = 0;
        while ($off < length $request) {
            my $n = syswrite($s, $request, length($request) - $off, $off);
            die "write: $!" unless $n;
            $off += $n;
        }
        while (sysread($s, my $part, 65536)) { $response .= $part }
        alarm 0;
        1;
    } or do { alarm 0; diag $@ };
    close $s;
    return $response;
}

{
    my $r = exchange("GET / HTTP/1.1\r\nHost:\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 400\b/, 'empty Host is rejected with 400';
    unlike $r, qr/host=/, 'rejected request never reaches the app';
}
{
    my $r = exchange("GET / HTTP/1.1\r\nHost:   \t \r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 400\b/, 'whitespace-only Host is rejected with 400';
}
{
    my $r = exchange("GET http:///p HTTP/1.1\r\nHost: good\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 200\b/, 'empty absolute-form authority still answers';
    like $r, qr/host=good/, 'empty authority does not erase a valid Host';
}
{
    my $r = exchange("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    like $r, qr/host=x/, 'ordinary Host keeps working';
}
{
    my $r = exchange("GET http://a.example/p HTTP/1.1\r\nHost: b\r\nConnection: close\r\n\r\n");
    like $r, qr/host=a\.example/, 'non-empty authority still overrides Host';
}

undef $cleanup;
done_testing;
