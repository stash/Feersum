#!perl
# Unrecognized methods get 501 without Allow (RFC 9110 15.6.2), unsupported
# versions 505 (RFC 9112 2.6), and an empty Transfer-Encoding 400.
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
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
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
    my $r = exchange("FOO / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 501\b/, 'an unknown method gets 501';
    unlike $r, qr/^Allow:/mi, 'a 501 names no method set';
}
{
    my $r = exchange("get / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 501\b/, 'methods stay case-sensitive';
}
{
    my $r = exchange("GET / HTTP/1.2\r\nHost: x\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 505\b/, 'a newer 1.x minor gets 505';
}
{
    my $r = exchange("GET / HTTP/2.0\r\nHost: x\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 505\b/, 'a cleartext HTTP/2 preface gets 505';
}
{
    my $r = exchange("POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding:\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 400\b/, 'an empty Transfer-Encoding is a 400';
}
{
    my $r = exchange("POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked foo\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 501\b/, 'junk after chunked is not chunked';
}
{
    my $r = exchange("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 200\b/, 'HTTP/1.1 still works';
}
{
    my $r = exchange("GET / HTTP/1.0\r\nConnection: close\r\n\r\n");
    like $r, qr/\AHTTP\/1\.0 200\b/, 'HTTP/1.0 still works';
}
{
    my $r = exchange("POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked;ext=1\r\nConnection: close\r\n\r\n0\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 200\b/, 'chunked with parameters still works';
}

undef $cleanup;
done_testing;
