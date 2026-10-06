#!perl
# A TLS writer that declines forever parks with the read watcher stopped; the
# drain of pending ciphertext must still honour max_read_buf and close.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use Time::HiRes qw(time sleep);
use Errno qw(EAGAIN EWOULDBLOCK);
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS unavailable' unless $probe->has_tls
    && eval { require IO::Socket::SSL; require Net::SSLeay; 1 } && tls_client_ok();

use constant CAP => 128 * 1024;
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;

my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my @keep;
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_keepalive(1);
    $f->max_read_buf(CAP);
    $f->read_timeout(20 * TMULT);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
        h2 => $probe->has_h2 ? 1 : 0);
    $f->psgi_request_handler(sub {
        return sub {
            my $respond = shift;
            my $w = $respond->([200, ['Content-Type', 'text/plain']]);
            $w->poll_cb(sub { return });
            push @keep, $w;
        };
    });
    my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

my $s = IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
    SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
    SSL_alpn_protocols => ['http/1.1'], Timeout => 5 * TMULT);
die 'TLS connect failed' unless $s;
syswrite($s, "GET /drain HTTP/1.1\r\nHost: x\r\n\r\n");

my $header = '';
eval {
    local $SIG{ALRM} = sub { die "no response\n" };
    alarm 5 * TMULT;
    while ($header !~ /\r\n\r\n/) {
        my $n = sysread($s, my $part, 4096);
        last unless $n;
        $header .= $part;
    }
    alarm 0; 1;
} or diag $@;
like $header, qr{^HTTP/1\.1 200}, 'streaming response began (writer is parked and declining)';

# flood past the cap without ever closing the write side
my $blob = 'x' x (16 * 1024);
my $closed = 0;
$s->blocking(0);
eval {
    local $SIG{ALRM} = sub { die "flood stalled\n" };
    alarm 12 * TMULT;
    my $sent = 0;
    while ($sent < 16 * CAP) {
        my $w = syswrite($s, $blob);
        if (defined $w) { $sent += $w; next }
        if ($! == EAGAIN || $! == EWOULDBLOCK) { sleep 0.01; next }
        $closed = 1; last;   # EPIPE/ECONNRESET: server closed under us
    }
    alarm 0; 1;
} or diag $@;

unless ($closed) {
    eval {
        local $SIG{ALRM} = sub { die "no close\n" };
        alarm 6 * TMULT;
        while (1) {
            my $n = sysread($s, my $part, 4096);
            if (defined $n) { $closed = 1, last if $n == 0; next }
            next if $! == EAGAIN || $! == EWOULDBLOCK;
            $closed = 1; last;
        }
        alarm 0; 1;
    } or diag $@;
}
ok $closed, 'flooded decline-drain is bounded: the server closes the connection';
close $s;
undef $cleanup;
done_testing;
