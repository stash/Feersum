#!perl
# An H2 tunnel (Extended CONNECT) is not killed by write_timeout: tunnels run
# over a socketpair and are exempt from the per-stream write deadline, so they
# keep working with a short timeout set.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();
plan skip_all => "Feersum not compiled with H2 support"
    unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available"
    if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 5;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "TLS+H2 configured";

use H2Utils;

# Short write timeout - must NOT kill tunnel streams
$evh->write_timeout(1.0 * TIMEOUT_MULT);

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

sub h2_send_extended_connect {
    my ($sock, $stream_id, $path, $port, $initial_data) = @_;
    my $headers_block = hpack_encode_headers(
        [':method',    'CONNECT'],
        [':protocol',  'websocket'],
        [':path',      $path],
        [':scheme',    'https'],
        [':authority',  "127.0.0.1:$port"],
    );
    my $out = h2_frame(H2_HEADERS, FLAG_END_HEADERS, $stream_id, $headers_block);
    if (defined $initial_data && length($initial_data) > 0) {
        $out .= h2_frame(H2_DATA, 0, $stream_id, $initial_data);
    }
    $sock->syswrite($out);
}

$evh->psgi_request_handler(sub {
    my $env = shift;

    if (($env->{HTTP_CONNECTION} || '') =~ /\bupgrade\b/i
        && $env->{HTTP_UPGRADE})
    {
        return sub {
            my $responder = shift;
            my $writer = $responder->([200, ['X-Tunnel' => 'accepted']]);
            my $io = $env->{'psgix.io'};
            unless ($io && ref($io)) {
                $writer->close();
                return;
            }
            # Echo with "echo:" prefix on first message, raw after that
            my $first = 1;
            my $handle; $handle = AnyEvent::Handle->new(
                fh       => $io,
                on_error => sub { $_[0]->destroy; undef $handle; },
                on_eof   => sub { $handle->destroy if $handle; undef $handle; },
            );
            $handle->on_read(sub {
                my $data = $handle->{rbuf};
                $handle->{rbuf} = '';
                if ($first) {
                    $handle->push_write("echo:$data");
                    $first = 0;
                } else {
                    $handle->push_write($data);
                }
            });
        };
    }

    return [200, ['Content-Type' => 'text/plain'], ['hello']];
});

# Tunnel should echo data even after waiting longer than write_timeout
h2_fork_test("tunnel survives write_timeout", $port, sub {
    my ($port) = @_;

    my ($sock) = h2_connect($port);
    exit(1) unless $sock;

    h2_send_extended_connect($sock, 1, '/tunnel', $port, "first-msg");

    # Read response HEADERS + echoed data
    my $got_200 = 0;
    my $echoed = '';
    my $expected = "echo:first-msg";
    my $deadline = time + 8 * TIMEOUT_MULT;
    while (length($echoed) < length($expected) && time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            my $status = hpack_decode_status($f->{payload});
            $got_200 = 1 if defined $status && $status eq '200';
        }
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $echoed .= $f->{payload};
        }
        if ($f->{type} == H2_DATA && length($f->{payload}) > 0) {
            my $wulen = length($f->{payload});
            $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $f->{stream_id}, pack('N', $wulen)));
            $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $wulen)));
        }
        last if $f->{type} == H2_RST_STREAM || $f->{type} == H2_GOAWAY;
    }
    exit(2) unless $got_200;
    exit(3) unless $echoed eq $expected;

    # Wait longer than write_timeout - tunnel must survive
    select(undef, undef, undef, 1.5 * TIMEOUT_MULT);

    # Send more data - if tunnel was killed by timeout, this would fail
    $sock->syswrite(h2_frame(H2_DATA, 0, 1, "after-timeout"));

    my $echoed2 = '';
    my $expected2 = "after-timeout";
    $deadline = time + 5 * TIMEOUT_MULT;
    while (length($echoed2) < length($expected2) && time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $echoed2 .= $f->{payload};
        }
        if ($f->{type} == H2_DATA && length($f->{payload}) > 0) {
            my $wulen = length($f->{payload});
            $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, $f->{stream_id}, pack('N', $wulen)));
            $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $wulen)));
        }
        last if $f->{type} == H2_RST_STREAM || $f->{type} == H2_GOAWAY;
    }

    # Clean close
    $sock->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, ''));
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
    $sock->close();

    exit($echoed2 eq $expected2 ? 0 : 4);
}, timeout_mult => TIMEOUT_MULT, timeout => 15);

pass "done";
