#!perl
# A quiet regular stream cannot excuse unread output in another stream or in
# the transport. Quiet sources and slowly progressing readers remain live.
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

sub headers {
    my ($id, $path) = @_;
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $id,
        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', 'x'], [':path', $path]));
}

sub read_body {
    my ($sock, $id, $paced) = @_;
    my ($buf, $body) = ('', '');
    my $deadline = time + 8 * TMULT;
    while (time < $deadline && length($body) < $size) {
        my $n = $sock->sysread(my $part, $paced ? 4096 : 65536);
        last if defined($n) && $n == 0;
        $buf .= $part if $n;
        while (length($buf) >= 9) {
            my ($hi, $lo, $type, $flags, $sid) = unpack('CnCCN', $buf);
            my $len = ($hi << 16) | $lo;
            last if length($buf) < 9 + $len;
            my $frame = substr($buf, 0, 9 + $len, '');
            return 0 if $type == H2_GOAWAY || $type == H2_RST_STREAM;
            $body .= substr($frame, 9) if $type == H2_DATA && $sid == $id;
        }
        select undef, undef, undef, $paced ? 0.04 * TMULT : 0.01;
    }
    warn sprintf "snapshot bytes=%d/%d\n", length($body), $size unless $body eq 'D' x $size;
    return $body eq 'D' x $size;
}

for my $api ('native', 'psgi') {
    for my $mode ('ciphertext stall', 'kernel stall', 'quiet first', 'quiet last',
                  'quiet control', 'paced ciphertext', 'paced kernel') {
        subtest "$api / $mode" => sub {
            plan skip_all => 'kernel send-queue probe unavailable' if $mode =~ /kernel/ && !$probe->has_outq_probe;
            my $flow = $mode =~ /quiet (?:first|last)/;
            my $large = $mode =~ /ciphertext|kernel/;
            my $paced = $mode =~ /paced/;
            my $must_reap = $mode =~ /stall/ || $flow;
            my $quiet_id = $mode eq 'quiet last' ? 3 : 1;
            my $body_id = $quiet_id == 1 ? 3 : 1;
            my ($listen, $port) = get_listen_socket();
            die "listen: $!" unless $listen;
            unless ($mode =~ /kernel/) {
                # whole TLS records fit, so the paced control avoids TCP window probes
                setsockopt($listen, SOL_SOCKET, SO_SNDBUF, pack('i', $paced ? 32768 : 4096))
                    or die "SO_SNDBUF: $!";
            }
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->max_connections(1);
            $f->linger_timeout(0);
            $f->read_timeout(0.5 * TMULT);
            is $f->write_timeout, 0, 'the default read watchdog must provide the bound';
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
            pipe(my $ready_r, my $ready_w) or die "pipe: $!";
            my $state = { closed => 0, body_requests => 0 };
            my $observed_server = $f;
            weaken($observed_server);
            my $start = sub {
                my $writer = shift;
                $state->{writer} = $writer;
                $writer->response_guard(guard { $state->{closed}++; delete $state->{writer} });
                # a stall must out-size the client receive buffer to stay on the
                # server; macOS autosizes it past a post-connect SO_RCVBUF, so the
                # client pins it small before connect (see h2_connect rcvbuf)
                $writer->write('D' x ($large && !$paced ? 2 * 1024 * 1024 : $size)) if $large;
                $writer->write('live') if $mode eq 'quiet control';
                $writer->poll_cb(sub { return });
                # sample before the client closes: its FIN sits behind queued data
                $state->{inspection} = EV::timer(2.5 * TMULT, 0, sub {
                    $state->{active_at_inspection} = $observed_server->active_conns;
                    syswrite($ready_w, 'R');
                });
            };
            if ($api eq 'psgi') {
                $f->psgi_request_handler(sub {
                    my $env = shift;
                    return sub { $start->(shift->([200, []])) } if $env->{PATH_INFO} eq '/quiet';
                    $state->{body_requests}++;
                    return [200, [], ['body']];
                });
            } else {
                $f->request_handler(sub {
                    my $req = shift;
                    if ($req->path eq '/quiet') { $start->($req->start_streaming(200, [])) }
                    else { $state->{body_requests}++; $req->send_response(200, [], 'body') }
                });
            }
            run_client 'quiet sources only exempt connections with no stalled output', sub {
                local $SIG{ALRM} = sub { die "client timeout\n" };
                alarm 12 * TMULT;
                # a stall needs the body to back up on the server, so pin a small
                # receive buffer before connect; autosizing would absorb it all
                my $sock = h2_connect($port, timeout => 3 * TMULT,
                    rcvbuf => $paced ? 32768 : $large ? 16384 : 65536) or return 10;
                my $cleanup = guard {
                    eval { $sock->syswrite(h2_frame(H2_RST_STREAM, 0, $quiet_id, pack('N', 8))
                        . ($flow ? h2_frame(H2_RST_STREAM, 0, $body_id, pack('N', 8)) : '')) };
                    close $sock;
                };
                my $batch;
                if ($flow) {
                    $batch = h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 0));
                    $batch .= $quiet_id == 1 ? headers(1, '/quiet') . headers(3, '/body')
                        : headers(1, '/body') . headers(3, '/quiet');
                } else {
                    $batch = $large ? h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 4 * 1024 * 1024))
                        . h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', 4 * 1024 * 1024)) : '';
                    $batch .= headers($quiet_id, '/quiet');
                }
                $sock->syswrite($batch);
                my $head = h2_read_until($sock, H2_HEADERS, $quiet_id, 3 * TMULT) or return 12;
                return 13 unless hpack_decode_status($head->{payload}) == 200;
                if ($paced) {
                    return 14 unless read_body($sock, $quiet_id, 1);
                } elsif ($mode eq 'quiet control') {
                    my $frame = h2_read_until($sock, H2_DATA, $quiet_id, 3 * TMULT) or return 15;
                    return 16 unless $frame->{payload} eq 'live';
                }
                return 17 unless sysread($ready_r, my $ready, 1) == 1;
                if (!$must_reap) {
                    $sock->syswrite(headers(3, '/probe'));
                    my ($body, $ended) = ('', 0);
                    my $deadline = time + 3 * TMULT;
                    while (time < $deadline && !$ended) {
                        my $frame = h2_read_frame($sock, 0.1) or next;
                        return 18 if $frame->{type} == H2_GOAWAY;
                        next unless $frame->{stream_id} == 3;
                        return 19 if $frame->{type} == H2_RST_STREAM;
                        $body .= $frame->{payload} if $frame->{type} == H2_DATA;
                        $ended = 1 if ($frame->{type} == H2_DATA || $frame->{type} == H2_HEADERS)
                            && ($frame->{flags} & FLAG_END_STREAM);
                    }
                    return 20 unless $ended && $body eq 'body';
                }
                alarm 0;
                return 0;
            };
            delete $state->{inspection};
            if ($must_reap) {
                is $state->{active_at_inspection}, 0, 'stalled output released sockets and streams before cancellation';
            } else {
                cmp_ok $state->{active_at_inspection} // 0, '>', 0, 'a healthy quiet or progressing connection stayed live';
            }
            is $state->{body_requests}, 1, 'the sibling reply reached the application' if $flow;
            my $cv = AE::cv;
            my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
            $f->graceful_shutdown(sub { $cv->send(1) });
            ok $cv->recv, 'shutdown completed';
            is $state->{closed}, 1, 'response guard ran exactly once';
            ok !exists $state->{writer}, 'source reference released';
            is $f->active_conns, 0, 'no admission slots retained';
            done_testing;
        };
    }
}
done_testing;
