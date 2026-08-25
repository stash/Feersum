#!perl
# An H2 stream reset while the app is still streaming into it makes write()
# fail, so the app drops its writer, the pseudo-conn is destroyed and its
# active_conns slot is released.  write_timeout(0) is the case under test
# because a non-zero one masks the leak by eventually killing the connection.
use warnings;
use strict;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use POSIX ();

my $feer = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support" unless $feer->has_tls();
plan skip_all => "Feersum not compiled with HTTP/2 support" unless $feer->has_h2();

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 5;

use AnyEvent;
use EV;

my $N_STREAMS = 8;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

$feer->use_socket($socket);
eval { $feer->set_tls(cert_file => $cert, key_file => $key, h2 => 1) };
is $@, '', "set_tls with h2";

$feer->write_timeout(0);          # no reaper: the leak has nothing to hide behind
$feer->read_timeout(60 * TMULT);

# A well-behaved streaming app: keeps writing from a timer, and drops the
# writer the moment write() signals failure.
our %HELD;
my $started = 0;
$feer->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'application/octet-stream']]);
        my $key = "$w";
        $HELD{$key} = $w;
        $started++;
        my $t;
        $t = AE::timer 0.05, 0.05, sub {
            unless (eval { $w->write('x' x 4096); 1 }) {
                undef $t;
                delete $HELD{$key};
            }
        };
    };
});

sub frame {
    my ($type, $flags, $sid, $payload) = @_;
    $payload = '' unless defined $payload;
    return pack('C3', (length($payload) >> 16) & 0xff,
                      (length($payload) >>  8) & 0xff,
                       length($payload)        & 0xff)
         . chr($type) . chr($flags) . pack('N', $sid & 0x7fffffff) . $payload;
}

use constant HPACK_GET => "\x82\x84\x87\x01\x09localhost";
use constant PREFACE   => "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

# The client MUST run in a forked child: this process is also the server, and
# a blocking select() here would starve the EV loop so the request would never
# be handled at all.
my $kid = fork;
die "fork: $!" unless defined $kid;
if (!$kid) {
    select undef, undef, undef, 0.4;
    my $s = IO::Socket::SSL->new(
        PeerAddr => '127.0.0.1', PeerPort => $port,
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2'],
        Timeout            => 5 * TMULT,
    ) or POSIX::_exit(10);
    syswrite($s, PREFACE . frame(0x4, 0, 0, ''));
    select undef, undef, undef, 0.3 * TMULT;
    sysread($s, my $ignored, 65536);
    syswrite($s, frame(0x4, 1, 0, ''));

    # Open N streams and let the app start streaming into each.
    my @sids = map { 1 + 2 * ($_ - 1) } 1 .. $N_STREAMS;
    syswrite($s, frame(0x1, 0x5, $_, HPACK_GET)) for @sids;
    select undef, undef, undef, 1.2 * TMULT;

    # Reset them all mid-response, then vanish.
    syswrite($s, frame(0x3, 0, $_, pack('N', 8))) for @sids;   # RST CANCEL
    select undef, undef, undef, 0.2 * TMULT;
    close $s;
    POSIX::_exit(0);
}

my $cv = AE::cv;
my $reaped;
my $child_w = AE::child($kid, sub { $reaped = $_[1] });
# Keep pumping for a while after the child exits so the app's timers get
# several ticks to notice the failure and drop their writers.
my $stop = AE::timer 8 * TMULT, 0, sub { $cv->send };
$cv->recv;
waitpid $kid, 0 unless defined $reaped;

cmp_ok $started, '>=', 1, "the app started streaming on at least one stream";

# The load-bearing assertions.  Pre-fix both were stuck at $N_STREAMS.
is scalar(keys %HELD), 0,
    "app was told its writers are dead and released all of them";
is $feer->active_conns, 0,
    "no pseudo-conn left pinned after the streams were reset";
