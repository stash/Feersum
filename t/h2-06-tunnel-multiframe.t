#!perl
use strict; use warnings;
use lib 't'; use Utils; use H2Utils;
use Test::More;
use Feersum; use EV;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);

plan skip_all => "no TLS" unless Feersum->new()->has_tls();
plan skip_all => "no H2" unless Feersum->new()->has_h2();
plan skip_all => "no certs" unless -f 'eg/ssl-proxy/server.crt';
eval { require IO::Socket::SSL; 1 } or plan skip_all => "no IO::Socket::SSL";
plan skip_all => "old SSL" unless tls_client_ok();

plan tests => 4;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";
my $evh = Feersum->new();
$evh->use_socket($socket);
$evh->set_tls(cert_file => 'eg/ssl-proxy/server.crt',
              key_file => 'eg/ssl-proxy/server.key', h2 => 1);

$evh->psgi_request_handler(sub {
    my $env = shift;
    if (($env->{HTTP_CONNECTION}||'') =~ /upgrade/i && $env->{HTTP_UPGRADE}) {
        return sub {
            my $responder = shift;
            $responder->([200, ['X-Tunnel' => 'ok']]);
            my $io = $env->{'psgix.io'};
            return unless $io;
            # Self-referential closure to keep $handle alive
            my $handle; $handle = AnyEvent::Handle->new(
                fh       => $io,
                on_error => sub { $_[0]->destroy; undef $handle },
                on_eof   => sub { $handle->destroy if $handle; undef $handle },
            );
            $handle->on_read(sub {
                my $data = $handle->{rbuf}; $handle->{rbuf} = '';
                $handle->push_write("echo:$data");
            });
        };
    }
    return [200, [], ['ok']];
});

ok $evh->has_h2(), "server configured with h2";

sub send_ec {
    my ($sock, $sid, $path, $port, $data) = @_;
    my $hdr = hpack_encode_headers(
        [':method', 'CONNECT'], [':protocol', 'websocket'],
        [':path', $path], [':scheme', 'https'],
        [':authority', "127.0.0.1:$port"],
    );
    my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid, $hdr);
    $out .= h2_frame(H2_DATA, 0, $sid, $data) if length($data);
    $sock->syswrite($out);
}

# Test: HEADERS alone, wait for 200, then send DATA
h2_fork_test("late-data", $port, sub {
    my ($port) = @_;
    my ($sock) = h2_connect($port);
    exit(1) unless $sock;

    # HEADERS only
    send_ec($sock, 1, '/tunnel', $port, '');

    # Wait for 200 HEADERS
    my $deadline = time + 5 * TMULT;
    my $got_200 = 0;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time) or last;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) { $got_200 = 1; last }
        last if $f->{type} == H2_GOAWAY || $f->{type} == H2_RST_STREAM;
    }
    exit(2) unless $got_200;

    # Send DATA separately
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "late-hello\n"));

    # Read echo
    my $echoed = '';
    $deadline = time + 5 * TMULT;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time) or last;
        $echoed .= $f->{payload} if $f->{type} == H2_DATA && $f->{stream_id} == 1;
        last if $f->{type} == H2_GOAWAY || $f->{type} == H2_RST_STREAM;
        last if $echoed =~ /echo:/;
        if ($f->{type} == H2_DATA && length($f->{payload}) > 0) {
            my $wulen = length($f->{payload});
            $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $f->{stream_id}, pack('N', $wulen)));
            $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $wulen)));
        }
    }

    $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
    $sock->close;
    exit($echoed =~ /echo:late-hello/ ? 0 : 3);
}, timeout_mult => TMULT, timeout => 10);
