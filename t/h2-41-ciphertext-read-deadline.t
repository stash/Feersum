#!perl
# The last stream can close before its TLS output drains. Progress still
# renews the read watchdog; a peer that stops reading still reaches its bound.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use Socket qw(SOL_SOCKET SO_SNDBUF SO_RCVBUF);
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $size = 256 * 1024;
# a stopped reader must leave real backlog on the server; a bounded body gets
# swallowed by the client receive buffer (macOS autosizes it), so pin the buffer
# small before connect (h2_connect rcvbuf) and out-size it with $big.
my $big = 2 * 1024 * 1024;

for my $api ('native', 'psgi') {
    for my $pace ('steady', 'stopped') {
        subtest "$api / $pace reader" => sub {
            my ($listen, $port) = get_listen_socket();
            die "listen: $!" unless $listen;
            setsockopt($listen, SOL_SOCKET, SO_SNDBUF, pack('i', 4096)) or die "SO_SNDBUF: $!";
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->max_connections(0);
            $f->linger_timeout(0);
            $f->read_timeout(0.5 * TMULT);
            is $f->write_timeout, 0, 'only the read watchdog bounds stalled output';
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
            pipe(my $ready_r, my $ready_w) or die "pipe: $!";
            my ($inspection, $reaped);
            my $inspect = sub {
                return unless $pace eq 'stopped';
                $inspection = EV::timer(2.5 * TMULT, 0, sub {
                    $reaped = $f->active_conns == 0;
                    syswrite($ready_w, 'R');
                });
            };
            my $body = 'D' x ($pace eq 'stopped' ? $big : $size);
            if ($api eq 'psgi') {
                $f->psgi_request_handler(sub { $inspect->(); [200, [], [$body]] });
            } else {
                $f->request_handler(sub { $inspect->(); shift->send_response(200, [], $body) });
            }
            run_client 'response already serialized with no further inbound frames', sub {
                local $SIG{ALRM} = sub { die "client timeout\n" };
                alarm 12 * TMULT;
                my $sock = h2_connect($port, timeout => 3 * TMULT, rcvbuf => 16384) or return 10;
                $sock->syswrite(h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 4 * 1024 * 1024))
                    . h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', 4 * 1024 * 1024))
                    . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
                        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                            [':authority', 'x'], [':path', '/big'])));
                if ($pace eq 'stopped') {
                    # The server samples its count before this socket closes.
                    return 12 unless sysread($ready_r, my $ready, 1) == 1;
                    close $sock;
                    alarm 0;
                    return 0;
                }
                my ($buf, $body, $ended, $status) = ('', '', 0, 0);
                my $start = time;
                my $deadline = $start + 8 * TMULT;
                while (time < $deadline && !$ended) {
                    my $n = $sock->sysread(my $part, 4096);
                    last if defined($n) && $n == 0;
                    $buf .= $part if $n;
                    while (length($buf) >= 9) {
                        my ($hi, $lo, $type, $flags, $id) = unpack('CnCCN', $buf);
                        my $len = ($hi << 16) | $lo;
                        last if length($buf) < 9 + $len;
                        my $frame = substr($buf, 0, 9 + $len, '');
                        return 13 if $type == H2_GOAWAY || $type == H2_RST_STREAM;
                        next unless $id == 1;
                        my $payload = substr($frame, 9);
                        $status = hpack_decode_status($payload) if $type == H2_HEADERS;
                        $body .= $payload if $type == H2_DATA;
                        $ended = 1 if ($type == H2_DATA || $type == H2_HEADERS) && ($flags & FLAG_END_STREAM);
                    }
                    select undef, undef, undef, 0.04 * TMULT;
                }
                warn sprintf "status=%d body=%d/%d ended=%d elapsed=%.2f\n",
                    $status, length($body), $size, $ended, time - $start
                    unless $status == 200 && $ended && $body eq 'D' x $size;
                return 14 unless $status == 200 && $ended && $body eq 'D' x $size;
                return 15 unless time - $start > 1.5 * TMULT;
                close $sock;
                alarm 0;
                return 0;
            };
            ok $reaped, 'stalled ciphertext was reaped while the peer kept its socket open'
                if $pace eq 'stopped';
            undef $inspection;
            my $cv = AE::cv;
            my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
            $f->graceful_shutdown(sub { $cv->send(1) });
            ok $cv->recv, 'shutdown completed';
            is $f->active_conns, 0, 'no sockets or streams retained';
            done_testing;
        };
    }
}
done_testing;
