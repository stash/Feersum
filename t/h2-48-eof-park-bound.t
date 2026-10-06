#!perl
# A parked H2 streaming reply past connection FIN fires on_eof and is reaped
# at eof_park_timeout; a stream's END_STREAM must neither fire nor bound it.
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    plan skip_all => "H2 not compiled in" unless $f->has_h2();
    eval { require IO::Socket::SSL; 1 }
        or plan skip_all => "IO::Socket::SSL not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 't/certs/alpha.crt' && -f 't/certs/alpha.key';
    plan tests => 8;
}

use IO::Socket::SSL;
use IO::Socket::INET;
use Socket qw(SHUT_WR SOMAXCONN);
use Time::HiRes qw(time sleep);
use File::Temp qw(tempdir);
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
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
$f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
$f->eof_park_timeout(2);
$f->linger_timeout(0);

my ($invites, $eof_fired, $guard_released, %kept);
$f->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'text/plain']]);
        my $id = "$w";
        $kept{$id} = $w;
        $w->response_guard(guard { $guard_released++; delete $kept{$id} });
        $w->on_eof(sub { $eof_fired++ });
        $w->poll_cb(sub { $invites++ });
    };
});

sub h2_get_request {
    my ($cli) = @_;
    my $auth = "127.0.0.1:$port";
    my $hb = "\x00\x07:method\x03GET" . "\x00\x07:scheme\x05https"
        . "\x00\x05:path\x01/" . "\x00\x0a:authority" . chr(length $auth) . $auth;
    my $out = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        . "\x00\x00\x00\x04\x00\x00\x00\x00\x00"
        . ("\x00\x00" . chr(length $hb) . "\x01\x05\x00\x00\x00\x01" . $hb);
    my $off = 0;
    while ($off < length($out)) {
        my $n = $cli->syswrite($out, length($out) - $off, $off);
        return 0 unless $n;
        $off += $n;
    }
    my ($buf, $saw_hdrs) = ('', 0);
    my $dl = time + 5 * TMULT;
    while (time < $dl && !$saw_hdrs) {
        my $n = $cli->sysread(my $p, 65536) or return 0;
        $buf .= $p;
        while (length($buf) >= 9) {
            my ($l1, $l2, $l3, $type, $flags, $sid) = unpack('CCCCCN', substr($buf, 0, 9));
            my $len = ($l1 << 16) | ($l2 << 8) | $l3;
            last if length($buf) < 9 + $len;
            substr($buf, 0, 9 + $len, '');
            $cli->syswrite("\x00\x00\x00\x04\x01\x00\x00\x00\x00")
                if $type == 0x4 && !($flags & 0x1);
            $saw_hdrs = 1 if $type == 0x1;
        }
    }
    return $saw_hdrs;
}

sub h2_connect {
    my $cli = IO::Socket::SSL->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5,
        SSL_verify_mode => 0, SSL_alpn_protocols => ['h2'],
    ) or return;
    return unless ($cli->alpn_selected() || '') eq 'h2';
    return $cli;
}

# FIN after response headers
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    $SIG{QUIT} = 'DEFAULT';
    select(undef, undef, undef, 0.5);
    my $cli = h2_connect() or POSIX::_exit(10);
    h2_get_request($cli) or POSIX::_exit(11);
    open my $fh, '>', "$dir/fin.mark" or POSIX::_exit(12);
    print $fh time, "\n";
    close $fh;
    CORE::shutdown($cli, SHUT_WR) or POSIX::_exit(13);
    $cli->blocking(0);
    my ($rbuf, $saw_goaway, $saw_eof) = ('', 0, 0);
    my $rdl = time + 3 * TMULT;
    while (time < $rdl && !$saw_eof) {
        my $n = $cli->sysread(my $p, 65536);
        if ($n) {
            $rbuf .= $p;
            while (length($rbuf) >= 9) {
                my ($a, $b, $c, $t, $fl, $s) = unpack('CCCCCN', substr($rbuf, 0, 9));
                my $ln = ($a << 16) | ($b << 8) | $c;
                last if length($rbuf) < 9 + $ln;
                substr($rbuf, 0, 9 + $ln, '');
                $saw_goaway = 1 if $t == 0x7;
            }
        } elsif (defined $n) {
            $saw_eof = 1;
        }
        sleep 0.05;
    }
    open my $lf, '>', "$dir/client.log" or POSIX::_exit(14);
    print $lf "goaway=$saw_goaway eof=$saw_eof\n";
    close $lf;
    POSIX::_exit(0);
}

my $cv = AE::cv;
my ($t0, $srv_drop);
my $sampler = AE::timer(0.05, 0.05, sub {
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
my $killer = AE::timer(9 * TMULT, 0, sub { $cv->send('timeout') });
my $reason = $cv->recv;
ok(!$reason, 'server reaped the FINned H2 stream');
is($eof_fired || 0, 1, 'on_eof fired once for the H2 writer');
is($guard_released || 0, 1, 'response guard released');
my $dt = (defined $srv_drop && $t0) ? $srv_drop - $t0 : -1;
ok($dt >= 0 && $dt < 2 + 1.5 * TMULT, sprintf('FIN->reap near the 2s bound (%.3fs)', $dt));
my $invites_at_reap = $invites;
my $quiet_cv = AE::cv;
my $quiet_t = AE::timer(1, 0, sub { $quiet_cv->send });
$quiet_cv->recv;
is($invites, $invites_at_reap, 'no poll invites after the bound reaped it');
my $log_cv = AE::cv;
my $log_t = AE::timer(0.1, 0.1, sub { $log_cv->send if -f "$dir/client.log" });
my $log_k = AE::timer(5 * TMULT, 0, sub { $log_cv->send });
$log_cv->recv;
my ($goaway, $cli_eof) = (0, 0);
if (-f "$dir/client.log") {
    open my $lf, '<', "$dir/client.log";
    my $line = <$lf>;
    ($goaway, $cli_eof) = ($1, $2) if $line && $line =~ /goaway=(\d) eof=(\d)/;
}
ok($goaway, 'client received GOAWAY after FIN (server observed EOF)');
kill 'QUIT', $pid; waitpid($pid, 0);
unlink "$dir/fin.mark", "$dir/client.log";

# a second FIN connection: the EOF latch must not leak across connections
($invites, $eof_fired, $guard_released) = (0, 0, 0);
%kept = ();
$pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    $SIG{QUIT} = 'DEFAULT';
    select(undef, undef, undef, 0.5);
    my $cli = h2_connect() or POSIX::_exit(10);
    h2_get_request($cli) or POSIX::_exit(11);
    open my $fh, '>', "$dir/fin2.mark" or POSIX::_exit(12);
    print $fh time, "\n";
    close $fh;
    CORE::shutdown($cli, SHUT_WR) or POSIX::_exit(13);
    sleep 5;   # outlast the fixed 2s park; parent kills on reap
    POSIX::_exit(0);
}
$cv = AE::cv;
($t0, $srv_drop) = (undef, undef);
$sampler = AE::timer(0.05, 0.05, sub {
    if (!$t0 && -f "$dir/fin2.mark") {
        open my $fh, '<', "$dir/fin2.mark" or return;
        chomp($t0 = <$fh>);
    }
    return unless $t0;
    if (!defined $srv_drop && $f->active_conns == 0) {
        $srv_drop = time;
        $cv->send;
    }
});
$killer = AE::timer(6 * TMULT, 0, sub { $cv->send('timeout') });
$reason = $cv->recv;
ok(!$reason && ($eof_fired || 0) == 1, 'second FIN connection fires and reaps');
kill 'QUIT', $pid; waitpid($pid, 0);
unlink "$dir/fin2.mark";

# END_STREAM only, no FIN
($invites, $eof_fired, $guard_released) = (0, 0, 0);
%kept = ();
$pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    $SIG{QUIT} = 'DEFAULT';
    select(undef, undef, undef, 0.5);
    my $cli = h2_connect() or POSIX::_exit(10);
    h2_get_request($cli) or POSIX::_exit(11);
    sleep 4 + 4 * TMULT;   # outlast the scaled quiet window below
    POSIX::_exit(0);
}
$quiet_cv = AE::cv;
$quiet_t = AE::timer(3 * TMULT, 0, sub { $quiet_cv->send });
$quiet_cv->recv;
ok(($eof_fired || 0) == 0 && $f->active_conns > 0 && $invites > 2,
    'END_STREAM-only stream healthy past the bound (no fire, no reap)');
kill 'QUIT', $pid; waitpid($pid, 0);
