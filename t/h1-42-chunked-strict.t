#!perl
# Chunk-size lines must be hex plus optional chunk-extensions and trailers
# must be field-lines (RFC 9112 7.1); garbage in either is a 400.
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
        my $body = '';
        my $len = $env->{CONTENT_LENGTH} || 0;
        $env->{'psgi.input'}->read($body, $len) if $len > 0;
        return [200, ['Content-Type' => 'text/plain'], ["BODY=$body"]];
    });
    my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

sub exchange {
    my ($body) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Timeout => 5 * TMULT) or die "connect: $!";
    my $request = "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
        . "Connection: close\r\n\r\n$body";
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
    my $r = exchange("5 xyz\r\nhello\r\n0\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 400\b/, 'junk after the chunk size is a 400';
    unlike $r, qr/BODY=/, 'rejected chunks never reach the app';
}
{
    my $r = exchange("5 ;x=y\r\nhello\r\n0\r\n\r\n");
    like $r, qr/BODY=hello/, 'whitespace around the extension stays accepted';
}
{
    my $r = exchange("5   \r\nhello\r\n0\r\n\r\n");
    like $r, qr/BODY=hello/, 'trailing whitespace after the size stays accepted';
}
{
    my $r = exchange("5;ext=1\r\nhello\r\n0\r\n\r\n");
    like $r, qr/BODY=hello/, 'a valid chunk extension still works';
}
{
    my $r = exchange("5\r\nhello\r\n0\r\nGarbageLine\r\n\r\n");
    like $r, qr/\AHTTP\/1\.1 400\b/, 'a trailer without a colon is a 400';
}
{
    my $r = exchange("5\r\nhello\r\n0\r\nX-Trailer: ok\r\n\r\n");
    like $r, qr/BODY=hello/, 'a valid trailer section still works';
}

undef $cleanup;
done_testing;
