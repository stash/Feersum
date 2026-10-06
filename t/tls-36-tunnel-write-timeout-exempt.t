#!perl
# write_timeout is disabled while the app holds a TLS tunnel socket: a stalled
# live tunnel with a parked relay backlog must deliver every byte, no EOF.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep);
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_SNDBUF SO_RCVBUF);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS unavailable' unless $probe->has_tls
    && eval { require IO::Socket::SSL; require Net::SSLeay; 1 } && tls_client_ok();
plan tests => 6;

my $BURST = 2 * 1024 * 1024;

my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
ok $listen, "listen on $port";

my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    # small buffers: a trickle read makes the socket writable again mid-backlog
    setsockopt($listen, SOL_SOCKET, SO_SNDBUF, pack('i', 32768)) or die "sndbuf: $!";
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key');
    $f->write_timeout(0.3);
    my %keep;
    my $chunk = 'x' x 65536;
    $f->request_handler(sub {
        my $conn = shift;
        my $io = $conn->io;
        my $st = { io => $io, left => $BURST };
        $keep{io} = $st;
        $st->{pump} = EV::io($io, EV::WRITE, sub {
            while ($st->{left} > 0) {
                my $n = syswrite($io, $chunk,
                    $st->{left} > length $chunk ? length $chunk : $st->{left});
                last unless $n;
                $st->{left} -= $n;
            }
            return if $st->{left} > 0;
            delete $st->{pump};   # quiet now, but %keep still holds the socket
            open my $out, '>', "$dir/pumped" or die $!;
            print {$out} "1\n";
            close $out;
        });
    });
    my $life = EV::timer(90 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

# SO_RCVBUF before connect pins the receive buffer; a post-connect set does not
# stop macOS autosizing, which would swallow the whole burst and hide the stall.
my $s = IO::Socket::INET->new(Proto => 'tcp', Blocking => 1) or die "socket: $!";
setsockopt($s, SOL_SOCKET, SO_RCVBUF, pack('i', 16384)) or die "rcvbuf: $!";
connect($s, Socket::pack_sockaddr_in($port, Socket::inet_aton('127.0.0.1')))
    or die "connect: $!";
IO::Socket::SSL->start_SSL($s, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE())
    or die "TLS: " . IO::Socket::SSL::errstr();
$s->print("GET /t HTTP/1.1\015\012Host: x\015\012Upgrade: test\015\012"
    . "Connection: Upgrade\015\012\015\012");

my $pumped = 0;
for (1 .. 200 * TMULT) {
    if (-f "$dir/pumped") { $pumped = 1; last; }
    sleep 0.05;
}
ok $pumped, 'app pumped the full burst, then went quiet';
sleep 0.3 * TMULT;   # let the relay park the backlog against a full sndbuf

my $got = 0;
for (1 .. 3) {
    my $n = sysread($s, my $b, 16384);
    $got += $n if $n;
    sleep 0.5 * TMULT;
}
cmp_ok $got, '>', 0, "trickle reads flowed pre-stall ($got bytes)";

sleep 2 * TMULT;   # full stall, well past three write_timeout intervals

my $eof = 0;
my $timed_out = 0;
eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 25 * TMULT;
    while ($got < $BURST) {
        my $n = sysread($s, my $b, 65536);
        if ($n) { $got += $n; next; }
        if (!defined $n && ($!{EAGAIN} || $!{ETIMEDOUT})) {
            $timed_out = 1;
            last;
        }
        $eof = 1;   # 0 or a fatal SSL error: the server reaped us
        last;
    }
    alarm 0;
};
$timed_out = 1 if $@ && $@ =~ /timeout/;
close $s;

ok !$timed_out, 'resume reads completed without timing out';
is $got, $BURST, "full burst arrived after the stall ($got bytes)";
ok !$eof, 'no EOF: live tunnel survived write_timeout';
