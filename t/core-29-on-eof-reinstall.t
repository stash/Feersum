#!perl
# Reinstalling on_eof from inside on_eof must not refire: the EOF latch is
# terminal, so the replacement stays stored but inert.
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    plan tests => 3;
}

use IO::Socket::INET;
use Socket qw(SHUT_WR SOMAXCONN);
use Time::HiRes qw(time sleep);

my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "listen: $!";
my $port = $sock->sockport;

my $f = Feersum->endjinn;
$f->use_socket($sock);
$f->eof_park_timeout(60);
$f->linger_timeout(0);

my ($fires, %kept, $writer);
my $cb;
$cb = sub {
    $fires++;
    $_[0]->on_eof($cb) if $fires < 4;
};
$f->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'text/plain']]);
        $writer = $w;
        $kept{"$w"} = $w;
        $w->on_eof($cb);
        $w->poll_cb(sub { });
    };
});

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    $SIG{QUIT} = 'DEFAULT';
    select(undef, undef, undef, 0.5);
    my $cli = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 5)
        or exit(10);
    $cli->syswrite("GET / HTTP/1.1\r\nHost: x\r\n\r\n") or exit(11);
    my ($raw, $dl) = ('', time + 5);
    while (time < $dl && index($raw, "\r\n\r\n") < 0) {
        my $n = $cli->sysread(my $p, 65536) or exit(12);
        $raw .= $p;
    }
    exit(13) unless $raw =~ m{^HTTP/1\.1 200}mi;
    CORE::shutdown($cli, SHUT_WR) or exit(14);
    sleep 3;
    exit(0);
}

my $cv = AE::cv;
my $watch = AE::timer(0.02, 0.02, sub { $cv->send if $fires });
my $killer = AE::timer(8, 0, sub { $cv->send('timeout') });
my $reason = $cv->recv;
my $quiet_cv = AE::cv;
my $quiet_t = AE::timer(1, 0, sub { $quiet_cv->send });
$quiet_cv->recv;
ok(!$reason, 'on_eof fired');
is($fires, 1, 'no refire from the mid-fire reinstall');
is(ref($writer->on_eof), 'CODE', 'replacement stays installed');
kill 'QUIT', $pid; waitpid($pid, 0);
