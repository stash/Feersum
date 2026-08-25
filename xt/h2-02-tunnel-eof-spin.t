#!perl
# After the app closes its psgix.io end of an Extended-CONNECT tunnel, the
# tunnel reader must not be re-armed on the EOF'd socket every loop iteration
# (no timeout reaps an established tunnel, so that spin would be permanent).
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use Time::HiRes qw(time);
use POSIX ();
use lib 't'; use Utils;
use Feersum;

my $evh = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();
plan skip_all => "Feersum not compiled with H2 support"  unless $evh->has_h2();
plan skip_all => "Linux-only (/proc CPU accounting)" unless $^O eq 'linux';

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;
eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available" if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
eval { require AnyEvent::Handle; 1 } or plan skip_all => "AnyEvent::Handle not available";

# 2 explicit below + 2 from h2_fork_test (did-not-hang + child-succeeded).
plan tests => 4;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";
$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

use H2Utils;

# The app relays one echo (so the tunnel is definitively established), then
# shuts down its end - the trigger for the server-side EOF path under test.
my %handles;
$evh->psgi_request_handler(sub {
    my $env = shift;
    return sub {
        my $responder = shift;
        my $writer = $responder->([200, ['X-Tunnel' => 'accepted']]);
        my $io = $env->{'psgix.io'};
        unless ($io && ref $io) { $writer->close; return }
        my $h; $h = AnyEvent::Handle->new(
            fh       => $io,
            on_error => sub { $_[0]->destroy; delete $handles{"$h"} },
            on_eof   => sub { $h->destroy if $h; delete $handles{"$h"} },
        );
        $h->on_read(sub {
            my $d = $h->{rbuf}; $h->{rbuf} = '';
            $h->push_write($d);
            $h->on_drain(sub { $h->push_shutdown });   # close our end after echo
        });
        $handles{"$h"} = $h;
    };
});

h2_fork_test("h2 tunnel EOF does not busy-spin", $port, sub {
    my ($port) = @_;

    # utime+stime of the server (our parent) in clock ticks.
    my $cpu_ticks = sub {
        open my $s, '<', "/proc/$_[0]/stat" or return undef;
        my $l = <$s>; close $s;
        return undef unless defined $l && (my $rest = $l) =~ s/^.*\)\s+//;
        my @f = split ' ', $rest;
        return $f[11] + $f[12];   # utime, stime (fields 14+15, 0-based past comm)
    };

    my $sock = h2_connect($port, timeout => 15 * TIMEOUT_MULT) or exit 1;
    my $hdrs = hpack_encode_headers(
        [':method', 'CONNECT'], [':protocol', 'websocket'],
        [':path', '/ws'], [':scheme', 'https'], [':authority', "127.0.0.1:$port"]);
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdrs));
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "hello"));

    # Read the echo, proving the tunnel established before the app shut its end.
    my $established = 0;
    my $dl = time + 6 * TIMEOUT_MULT;
    while (time < $dl) {
        my $f = h2_read_frame($sock, $dl - time) or last;
        $established = 1, last if $f->{type} == H2_DATA && $f->{stream_id} == 1;
    }
    exit 2 unless $established;

    # Hold our half open (no END_STREAM, no RST) and read nothing; the server is
    # now at EOF on the relay socket.  Measure its CPU over the window: a spin is
    # ~one full core-second per wall-second.
    my $ppid = getppid();
    my $t0 = $cpu_ticks->($ppid);
    exit 3 unless defined $t0;
    my $window = 2 * TIMEOUT_MULT;
    select undef, undef, undef, $window;
    my $t1 = $cpu_ticks->($ppid);
    my $hz = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
    my $cpu = ($t1 - $t0) / $hz;
    $sock->close;
    my $rc = $cpu <= 0.5 * $window ? 0 : 5;   # generous: post-fix is ~idle
    warn sprintf "tunnel EOF busy-spin: %.2f CPU-sec in a %.2fs window\n",
        $cpu, $window if $rc;
    exit($rc);
});
