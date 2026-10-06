#!perl
# Control-only sessions remain evictable. A serialized END_STREAM must not
# make a session evictable until its ciphertext has reached the socket.
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
# A queued reply must out-size the client receive buffer to leave backlog on
# the server. macOS autosizes that buffer past a small post-connect SO_RCVBUF;
# a pre-connect one (see h2_connect rcvbuf) pins it near 300KB, so 2MB clears it.
my $big = 2 * 1024 * 1024;

sub headers {
    my ($path) = @_;
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', 'x'], [':path', $path]));
}

# Read several frames per SSL read, keeping large replies quick on slow VMs.
sub read_reply {
    my ($sock, $want, $status) = @_;
    $status //= 0;
    my ($buf, $body, $ended) = ('', '', 0);
    my $deadline = time + 6 * TMULT;
    while (time < $deadline && !$ended) {
        my $n = $sock->sysread(my $part, 65536);
        last if defined($n) && $n == 0;
        if (!$n) { select undef, undef, undef, 0.01; next }
        $buf .= $part;
        while (length($buf) >= 9) {
            my ($hi, $lo, $type, $flags, $id) = unpack('CnCCN', $buf);
            my $len = ($hi << 16) | $lo;
            last if length($buf) < 9 + $len;
            my $frame = substr($buf, 0, 9 + $len, '');
            return 0 if $type == H2_GOAWAY || $type == H2_RST_STREAM;
            next unless $id == 1;
            my $payload = substr($frame, 9);
            $status = hpack_decode_status($payload) if $type == H2_HEADERS;
            $body .= $payload if $type == H2_DATA;
            $ended = 1 if ($type == H2_HEADERS || $type == H2_DATA) && ($flags & FLAG_END_STREAM);
        }
    }
    warn sprintf("reply status=%d bytes=%d/%d ended=%d\n", $status, length($body), length($want), $ended)
        unless $status == 200 && $ended && $body eq $want;
    return $status == 200 && $ended && $body eq $want;
}

for my $api ('native', 'psgi') {
    for my $traffic ('preface', 'settings', 'ping', 'completed stream and ping',
                     'partial TLS record', 'queued reply') {
        subtest "$api / $traffic" => sub {
            my ($listen, $port) = get_listen_socket();
            die "listen: $!" unless $listen;
            setsockopt($listen, SOL_SOCKET, SO_SNDBUF, pack('i', 4096)) or die "SO_SNDBUF: $!";
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->max_connections(1);
            $f->linger_timeout(0);
            $f->read_timeout(30 * TMULT);
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
            my @paths;
            if ($api eq 'psgi') {
                $f->psgi_request_handler(sub {
                    my $env = shift;
                    push @paths, $env->{PATH_INFO};
                    return [200, [], [$paths[-1] eq '/big' ? 'D' x $big : 'probe']];
                });
            } else {
                $f->request_handler(sub {
                    my $req = shift;
                    push @paths, $req->env->{PATH_INFO};
                    $req->send_response(200, [], $paths[-1] eq '/big' ? 'D' x $big : 'probe');
                });
            }
            run_client 'admission accounts for control traffic and pending output', sub {
                local $SIG{ALRM} = sub { die "client timeout\n" };
                alarm 13 * TMULT;
                my $old = h2_connect($port, timeout => 3 * TMULT,
                    $traffic eq 'queued reply' ? (rcvbuf => 16384) : ()) or return 10;
                if ($traffic eq 'queued reply') {
                    # windows fit the whole body; then stop reading during the eviction try
                    $old->syswrite(h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 4 * 1024 * 1024))
                        . h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', 4 * 1024 * 1024)) . headers('/big'));
                    my $head = h2_read_until($old, H2_HEADERS, 1, 3 * TMULT) or return 12;
                    return 13 unless hpack_decode_status($head->{payload}) == 200;
                    my $excess = h2_connect($port, timeout => 1 * TMULT);
                    return 14 if $excess;
                    return 15 unless read_reply($old, 'D' x $big, 200);
                } else {
                    if ($traffic eq 'completed stream and ping') {
                        $old->syswrite(headers('/first'));
                        return 16 unless read_reply($old, 'probe');
                    }
                    if ($traffic =~ /ping/) {
                        $old->syswrite(h2_frame(H2_PING, 0, 0, '12345678'));
                        my $ack = h2_read_until($old, H2_PING, 0, 3 * TMULT) or return 17;
                        return 18 unless ($ack->{flags} & FLAG_ACK) && $ack->{payload} eq '12345678';
                    } elsif ($traffic eq 'settings') {
                        $old->syswrite(h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 65536)));
                        my $ack = h2_read_until($old, H2_SETTINGS, 0, 3 * TMULT) or return 19;
                        return 20 unless $ack->{flags} & FLAG_ACK;
                    } elsif ($traffic eq 'partial TLS record') {
                        # A split TLS record produces no HTTP/2 callback yet.
                        open my $raw, '+<&', fileno($old) or return 23;
                        return 24 unless syswrite($raw, "\x17") == 1;
                        close $raw;
                        select undef, undef, undef, 0.1 * TMULT;
                    }
                }
                # old socket stays open: admission must evict it once idle
                my $fresh = h2_connect($port, timeout => 3 * TMULT) or return 21;
                $fresh->syswrite(headers('/probe'));
                return 22 unless read_reply($fresh, 'probe');
                close $fresh;
                close $old;
                alarm 0;
                return 0;
            };
            my @expected = $traffic eq 'queued reply' ? ('/big', '/probe')
                : $traffic eq 'completed stream and ping' ? ('/first', '/probe') : ('/probe');
            is_deeply \@paths, \@expected, 'all admitted requests ran exactly once';
            my $cv = AE::cv;
            my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
            $f->graceful_shutdown(sub { $cv->send(1) });
            ok $cv->recv, 'connections released and shutdown completed';
            is $f->active_conns, 0, 'no sockets or pseudo-connections retained';
            done_testing;
        };
    }
}
done_testing;
