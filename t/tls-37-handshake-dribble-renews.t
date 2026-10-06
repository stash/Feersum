#!perl
# A TLS handshake making steady progress must renew the read deadline; only a
# stalled one times out. A dribble proxy slows a real client's first flight.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time sleep);


my $probe = Feersum->new_instance;
plan skip_all => 'TLS unavailable' unless $probe->has_tls && tls_client_ok();
plan skip_all => 'IO::Socket::SSL unavailable'
    unless eval { require IO::Socket::SSL; 1 };

my ($srv_listen, $srv_port) = get_listen_socket();
die "listen: $!" unless $srv_listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($srv_listen);
    $f->read_timeout(2);
    $f->header_timeout(30);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 0);
    $f->psgi_request_handler(sub {
        return [200, ['Content-Type' => 'text/plain'], ['dribbled-ok']];
    });
    my $life = EV::timer(60, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $srv_listen;

my ($fwd_listen, $fwd_port) = get_listen_socket();
die "listen: $!" unless $fwd_listen;
$fwd_listen->listen(10) or die "listen: $!";
$fwd_listen->blocking(1);
my $fwd = fork;
die "fork: $!" unless defined $fwd;
if (!$fwd) {
    close $srv_listen;
    my $down = $fwd_listen->accept or POSIX::_exit(1);
    my $up = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $srv_port,
        Proto => 'tcp', Timeout => 10) or POSIX::_exit(1);
    $down->blocking(0);
    $up->blocking(0);
    my $t0 = time;
    my $c2s_bytes = 0;
    my ($down_eof, $up_eof) = (0, 0);
    while (!$down_eof || !$up_eof) {
        last if time - $t0 > 45;
        my ($rin, $rout) = ('', '');
        vec($rin, fileno($down), 1) = 1 unless $down_eof;
        vec($rin, fileno($up), 1) = 1 unless $up_eof;
        last unless select($rin, undef, undef, 5) > 0;
        if (vec($rin, fileno($up), 1)) {
            my $n = sysread($up, my $buf, 65536);
            if (!$n) { $up_eof = 1; shutdown $down, 1; }
            else { syswrite($down, $buf) }
        }
        if (vec($rin, fileno($down), 1)) {
            my $n = sysread($down, my $buf, 100);
            if (!$n) { $down_eof = 1; shutdown $up, 1; }
            else {
                $c2s_bytes += $n;
                syswrite($up, $buf);
                sleep 0.25 if $c2s_bytes < 4096;
            }
        }
    }
    POSIX::_exit(0);
}
my $fwd_cleanup = guard { kill 'KILL', $fwd; waitpid $fwd, 0 };
close $fwd_listen;

my $t0 = time;
my $cl = IO::Socket::SSL->new(
    PeerAddr => '127.0.0.1', PeerPort => $fwd_port,
    SSL_hostname => 'alpha.local', SSL_verify_mode => 0, Timeout => 30,
);
my $resp = '';
if ($cl) {
    print $cl "GET / HTTP/1.0\r\nHost: alpha.local\r\n\r\n";
    local $SIG{ALRM} = sub { die "read timeout\n" };
    alarm 20;
    $resp .= $_ while <$cl>;
    alarm 0;
    close $cl;
}
my $elapsed = time - $t0;
cmp_ok $elapsed, '>', 1.5, sprintf 'the dribble was in flight for seconds (%.1fs)', $elapsed;
like $resp, qr/\AHTTP\/1\.[01] 200\b/, 'a progressing handshake survives read_timeout';
like $resp, qr/dribbled-ok/, 'the dribbled connection serves the request';

undef $fwd_cleanup;
undef $cleanup;
done_testing;
