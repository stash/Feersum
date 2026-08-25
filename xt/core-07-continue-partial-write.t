#!perl
# A partial write of the 100 Continue interim response must not complete the
# response: the request is still being received, so its body must reach the
# handler, not be reparsed as the next keepalive request.
# Author-only: forces the partial write with an LD_PRELOAD shim (Linux + cc).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use Config;
use lib 't'; use Utils;
use IO::Socket::INET ();
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep);

BEGIN {
    plan skip_all => 'LD_PRELOAD shim is Linux-only' unless $^O eq 'linux';
}

my $dir = tempdir(CLEANUP => 1);

# A shim that truncates the first write of the 25-byte 100 Continue to 10 bytes,
# as a nearly full socket send buffer would.
my $cc = $Config{cc} or plan skip_all => 'no C compiler';
open my $ch, '>', "$dir/shim.c" or die $!;
print $ch <<'C'; close $ch;
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
static const char CONT[] = "HTTP/1.1 100 Continue\r\n\r\n";
ssize_t write(int fd, const void *buf, size_t count) {
    static ssize_t (*real)(int, const void *, size_t);
    if (!real) real = (ssize_t(*)(int,const void*,size_t))dlsym(RTLD_NEXT,"write");
    if (count == sizeof(CONT)-1 && memcmp(buf, CONT, count) == 0)
        return real(fd, buf, 10);
    return real(fd, buf, count);
}
C
system("$cc -shared -fPIC -o $dir/shim.so $dir/shim.c -ldl 2>$dir/cc.err") == 0
    && -f "$dir/shim.so"
    or plan skip_all => "shim build failed: " . do { local(@ARGV,$/)=("$dir/cc.err"); <> // '' };

plan tests => 2;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my ($lsock, $port) = get_listen_socket();
my $marker = "$dir/marker";

# The server must be started with the shim preloaded, so exec a fresh perl.
open my $sh, '>', "$dir/srv.pl" or die $!;
print $sh <<'SRV'; close $sh;
use strict; use warnings;
use lib 'blib/lib', 'blib/arch';
use Feersum; use EV; use POSIX ();
my ($fd, $marker) = @ARGV;
open my $ls, "+<&=$fd" or die "fdopen: $!";
my $f = Feersum->new; $f->set_keepalive(1); $f->read_timeout(3); $f->use_socket($ls);
$f->psgi_request_handler(sub {
    my $env = shift;
    open my $m, '>>', $marker or return;
    print $m "path=$env->{PATH_INFO} clen=".($env->{CONTENT_LENGTH}//'-')."\n";
    close $m;
    my $body = '';
    $env->{'psgi.input'}->read($body, $env->{CONTENT_LENGTH}) if $env->{CONTENT_LENGTH};
    open $m, '>>', $marker; print $m "body_bytes=".length($body)."\n"; close $m;
    [200, ['Content-Type'=>'text/plain'], ['ok']];
});
my $life = EV::timer(20, 0, sub { EV::break() });
EV::run();
POSIX::_exit(0);
SRV

use Fcntl qw(F_SETFD F_GETFD FD_CLOEXEC);
my $spid = fork // die "fork: $!";
if (!$spid) {
    $ENV{LD_PRELOAD} = "$dir/shim.so";
    $ENV{PERL_TEST_TIME_OUT_FACTOR} = TIMEOUT_MULT;
    my $fd = fileno($lsock);
    fcntl($lsock, F_SETFD, 0);      # clear close-on-exec so the fd survives exec
    open STDERR, '>', "$dir/srv.err";
    exec $Config{perlpath}, "$dir/srv.pl", $fd, $marker
        or POSIX::_exit(127);
}
close $lsock;
sleep 0.6 * TIMEOUT_MULT;

my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
    Timeout => 5 * TIMEOUT_MULT) or die "connect: $!";
my $body = "PADDINGxPADDING";        # a harmless body; must reach the handler
$c->syswrite("POST /first HTTP/1.1\r\nHost: x\r\nContent-Length: "
    . length($body) . "\r\nExpect: 100-continue\r\n\r\n");
sleep 0.5 * TIMEOUT_MULT;             # wait past the interim, then send the body
$c->syswrite($body);
sleep 1.0 * TIMEOUT_MULT;
close $c;

kill 'QUIT', $spid; waitpid $spid, 0;

my $m = do { local (@ARGV,$/) = ($marker); -e $marker ? <> : '' };
my $blen = length($body);
like $m, qr{path=/first\b}, "the POST handler ran for its own request"
    or diag "server markers:\n$m";
like $m, qr{body_bytes=$blen\b}, "the handler received the full body, not reparsed as a request"
    or diag "server markers:\n$m";
