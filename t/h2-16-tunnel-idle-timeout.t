#!perl
# An established RFC 8441 tunnel is not an idle connection.  The H1 and TLS
# tunnels stop the read/write timers at takeover; the H2 branch cannot (sibling
# streams still need the bound), so conn_read_timeout used to GOAWAY a live
# websocket after read_timeout seconds of silence.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use Time::HiRes qw(time);
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();
plan skip_all => "Feersum not compiled with H2 support"  unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available" if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

eval { require AnyEvent::Handle; 1 }
    or plan skip_all => "AnyEvent::Handle not available";

plan tests => 4;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

# Short enough that the test is quick, long enough to survive a loaded smoker.
my $RTO = 1 * TIMEOUT_MULT;
$evh->read_timeout($RTO);

use H2Utils;

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
        $h->on_read(sub { my $d = $h->{rbuf}; $h->{rbuf} = ''; $h->push_write($d) });
        $handles{"$h"} = $h;
    };
});

h2_fork_test("idle tunnel survives read_timeout", $port, sub {
    my ($port) = @_;

    my $sock = h2_connect($port) or exit 1;

    my $hdrs = hpack_encode_headers(
        [':method', 'CONNECT'], [':protocol', 'websocket'],
        [':path', '/ws'], [':scheme', 'https'], [':authority', "127.0.0.1:$port"]);
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdrs));
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "hello"));

    # Wait for the echo, proving the tunnel is established.
    my $established = 0;
    my $dl = time + 6 * TIMEOUT_MULT;
    while (time < $dl) {
        my $f = h2_read_frame($sock, $dl - time) or last;
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) { $established = 1; last }
    }
    exit 2 unless $established;

    # Go quiet for well over read_timeout.
    my $goaway = 0;
    my $silent_until = time + 3 * $RTO;
    while (time < $silent_until) {
        my $f = h2_read_frame($sock, 0.5) or next;
        if ($f->{type} == H2_GOAWAY) { $goaway = 1; last }
    }
    exit 3 if $goaway;

    # The tunnel must still relay.
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "still-there"));
    my $alive = 0;
    my $dl2 = time + 5 * TIMEOUT_MULT;
    while (time < $dl2) {
        my $f = h2_read_frame($sock, $dl2 - time) or last;
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) { $alive = 1; last }
        if ($f->{type} == H2_GOAWAY) { last }
    }
    $sock->close;
    exit($alive ? 0 : 4);
});
