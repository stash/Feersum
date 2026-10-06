#!perl
# A TLS streaming writer closed inside on_eof must close promptly (~0.05s),
# not sit out the post-EOF poll-retry park (~1s).
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    eval { require IO::Socket::SSL; 1 }
        or plan skip_all => "IO::Socket::SSL not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 't/certs/alpha.crt' && -f 't/certs/alpha.key';
    plan tests => 5;
}

use IO::Socket::SSL;
use IO::Socket::INET;
use Socket qw(SHUT_WR SOMAXCONN);
use Time::HiRes qw(time sleep);
use File::Temp qw(tempdir);
use POSIX ();

my $dir = tempdir(CLEANUP => 1);

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
$f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 0);
$f->eof_park_timeout(60);
$f->linger_timeout(0);

my ($invites, $eof_fired, $guard_released, %kept);
$f->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'text/plain']]);
        my $id = "$w";
        $kept{$id} = $w;
        $w->response_guard(guard { $guard_released++; delete $kept{$id} });
        $w->on_eof(sub { $eof_fired++; $_[0]->close; delete $kept{$id} });
        $w->poll_cb(sub { $invites++ });
    };
});

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    $SIG{QUIT} = 'DEFAULT';
    select(undef, undef, undef, 0.5);
    my $cli = IO::Socket::SSL->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5,
        SSL_verify_mode => 0, SSL_alpn_protocols => ['http/1.1'],
    ) or POSIX::_exit(10);
    $cli->syswrite("GET / HTTP/1.1\r\nHost: x\r\n\r\n") or POSIX::_exit(11);
    my ($raw, $dl) = ('', time + 5);
    while (time < $dl && index($raw, "\r\n\r\n") < 0) {
        my $n = $cli->sysread(my $p, 65536) or POSIX::_exit(12);
        $raw .= $p;
    }
    POSIX::_exit(13) unless $raw =~ m{^HTTP/1\.1 200}mi;
    sleep 1.5; # saturate the poll-retry backoff ladder while the peer is live
    open my $fh, '>', "$dir/fin.mark" or POSIX::_exit(14);
    print $fh time, "\n";
    close $fh;
    CORE::shutdown($cli, SHUT_WR) or POSIX::_exit(15);
    $dl = time + 8;
    while (time < $dl) {
        my $n = $cli->sysread(my $p, 65536);
        last if !$n;
    }
    POSIX::_exit(0);
}

my $cv = AE::cv;
my ($t0, $srv_drop);
my $sampler = AE::timer(0.01, 0.02, sub {
    if (!$t0 && -f "$dir/fin.mark") {
        open my $fh, '<', "$dir/fin.mark" or return;
        chomp($t0 = <$fh>);
    }
    return unless $t0;
    if (!defined $srv_drop && $f->active_conns == 0) {
        $srv_drop = time;
        $cv->send;
    }
});
my $killer = AE::timer(25, 0, sub { $cv->send('timeout') });
my $reason = $cv->recv;
ok(!$reason, 'server reaped the connection');
is($eof_fired || 0, 1, 'on_eof fired once');
is($guard_released || 0, 1, 'response guard released');
cmp_ok($invites, '>=', 11, 'backoff ladder saturated pre-FIN');
my $dt = (defined $srv_drop && $t0) ? $srv_drop - $t0 : -1;
cmp_ok($dt, '<', 0.5, sprintf('FIN->close prompt (%.3fs), no stale park', $dt));

kill 'QUIT', $pid; waitpid($pid, 0);
unlink "$dir/fin.mark";
