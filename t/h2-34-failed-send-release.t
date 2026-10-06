#!perl
# A disconnect between receiving a frame and sending its reply must not
# re-arm the read timer on a closed socket and retain its admission slot.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use Socket qw(SOL_SOCKET SO_LINGER);
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my $stats = "$dir/stats";
my $log = "$dir/server.log";
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    open STDERR, '>', $log or die $!;
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->max_connections(1);
    $f->read_timeout(30 * TMULT);
    $f->header_timeout(30 * TMULT);
    $f->psgi_request_handler(sub { return [200, [], ['ok']] });
    my $report = EV::timer(0, 0.02, sub {
        open my $out, '>', "$stats.tmp" or die $!;
        print {$out} $f->active_conns, "\n";
        close $out;
        rename "$stats.tmp", $stats or die $!;
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { kill 'CONT', $pid; reap_server($pid) };
close $listen;

sub wait_active {
    my ($want) = @_;
    my $deadline = time + 2 * TMULT;
    while (time < $deadline) {
        if (open my $in, '<', $stats) {
            my $active = <$in>;
            close $in;
            return 1 if defined $active && $active =~ /^$want\s*$/;
        }
        select undef, undef, undef, 0.02;
    }
    return 0;
}

my $s = h2_connect($port) or die 'H2 connect failed';
ok wait_active(1), 'the client occupies the single admission slot';

# paused so PING and RST queue together: the read succeeds, the ACK write fails
kill 'STOP', $pid or die "stop server: $!";
{
    local $SIG{ALRM} = sub { die "server did not stop\n" };
    alarm 5 * TMULT;
    waitpid($pid, POSIX::WUNTRACED()) == $pid or die "wait for stop: $!";
    alarm 0;
}
my $frame = h2_frame(H2_PING, 0, 0, 'departed');
is $s->syswrite($frame), length($frame), 'queued the PING while the server was paused';
select undef, undef, undef, 0.05;
setsockopt($s, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) or die "linger: $!";
$s->close(SSL_no_shutdown => 1);
select undef, undef, undef, 0.05;
kill 'CONT', $pid or die "resume server: $!";

ok wait_active(0), 'the failed send releases the connection before read_timeout';
open my $in, '<', $log or die $!;
my $errors = do { local $/; <$in> };
close $in;
like $errors, qr/(?:TLS flush error in H2 session_send|nghttp2_session_send error)/,
    'the regression exercised the H2 send failure';

my $next = h2_connect($port, timeout => 2 * TMULT);
ok $next, 'another client is admitted immediately';
if ($next) {
    $next->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
                           "\x82\x84\x87\x01\x01x"));
    my $headers = h2_read_until($next, H2_HEADERS, 1, 2 * TMULT);
    is $headers ? hpack_decode_status($headers->{payload}) : 'no response', 200,
        'the replacement connection serves a normal request';
    close $next;
} else {
    fail 'the replacement connection serves a normal request';
}
ok wait_active(0), 'all connection resources are released';
done_testing;
