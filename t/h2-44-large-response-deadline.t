#!perl
# Sendable DATA held behind the TLS buffer must follow transport progress.
# Flow-controlled siblings and application write gaps keep their own deadlines.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use Socket qw(SOL_SOCKET SO_SNDBUF SO_RCVBUF);
use Time::HiRes qw(time);
use IO::Socket::INET ();
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use constant TPUT_HEADROOM => 5;   # sustained TLS throughput must clear this x the paced read rate

# Loopback TLS bulk-throughput probe. A box that cannot clear the paced read
# rate with headroom (a no-AES armv6l smoker under parallel load) has its slow
# reader reaped mid-stream before the transport-progress deadline is exercised,
# so the whole file skips rather than false-fails. Returns MB/s, 0 on a transfer
# that could not finish in time, or undef on a setup error (caller runs anyway).
sub tls_mb_per_s {
    return undef unless -r 't/certs/alpha.crt' && -r 't/certs/alpha.key';
    my ($lsock, $lport) = get_listen_socket() or return undef;
    my $bytes = 8 * 1024 * 1024;
    my $pid = fork;
    return undef unless defined $pid;
    if (!$pid) {
        $SIG{QUIT} = 'DEFAULT';
        $lsock->blocking(1);
        my $c = $lsock->accept;
        if ($c && IO::Socket::SSL->start_SSL($c, SSL_server => 1,
                SSL_cert_file => 't/certs/alpha.crt', SSL_key_file => 't/certs/alpha.key')) {
            my $chunk = 'D' x 65536;
            my $left = $bytes;
            while ($left > 0) {
                my $n = syswrite($c, $chunk, $left < 65536 ? $left : 65536);
                last unless $n;
                $left -= $n;
            }
        }
        close $c if $c;
        POSIX::_exit(0);
    }
    close $lsock;
    my ($mbps, $timed_out);
    eval {
        local $SIG{ALRM} = sub { $timed_out = 1; die "probe timeout\n" };
        alarm 20 * TMULT;
        my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $lport,
            Proto => 'tcp', Timeout => 5 * TMULT) or die "connect: $!\n";
        IO::Socket::SSL->start_SSL($c, SSL_verify_mode => 0) or die "ssl handshake failed\n";
        my ($got, $start) = (0, time);
        while ($got < $bytes) {
            my $n = sysread($c, my $part, 65536);
            last unless $n;
            $got += $n;
        }
        my $el = time - $start;
        close $c;
        $mbps = $el > 0 ? ($got / 1048576) / $el : undef;
        alarm 0;
    };
    reap_server($pid, 5);
    return 0 if $timed_out;   # could not move 8 MiB in 20*TMULT: too slow
    return $mbps;
}

my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $size = 18 * 1024 * 1024; # exceed the 16 MiB ciphertext cap
my $window = 32 * 1024 * 1024;
my $wt = ($probe->has_outq_probe ? 0.2 : 1) * TMULT;
# reader rate: the reply spans several write deadlines whatever the sleep granularity
my $pace = $size / (8 * $wt);

my $need_mb_s = TPUT_HEADROOM * $pace / 1048576;
my $tput = tls_mb_per_s();
plan skip_all => sprintf('TLS throughput %.1f MB/s lacks headroom over paced %.1f MB/s',
    $tput, $pace / 1048576) if defined($tput) && $tput < $need_mb_s;
diag sprintf 'TLS loopback throughput ~%.0f MB/s (need ~%.0f)', $tput, $need_mb_s if defined $tput;

{
    package LargeProgressBody;
    sub getline {
        my ($self) = @_;
        return undef unless $self->{left};
        my $n = $self->{left} < 16384 ? $self->{left} : 16384;
        $self->{left} -= $n;
        return 'D' x $n;
    }
    sub close {
        my ($self) = @_;
        $self->{state}{body_closed}++;
        delete $self->{env};
        return;
    }
}

sub headers {
    my ($id, $path) = @_;
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $id,
        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', 'x'], [':path', $path]));
}

for my $case (
    ['native', 'whole', 'reading'], ['psgi', 'whole', 'reading'],
    ['native', 'writer', 'reading'], ['psgi', 'writer', 'reading'],
    ['native', 'poll', 'reading'], ['psgi', 'poll', 'reading'],
    ['psgi', 'io', 'reading'],
    ['native', 'whole', 'mixed'], ['psgi', 'whole', 'mixed'],
    ['native', 'whole', 'stalled'], ['psgi', 'whole', 'stalled'],
) {
    my ($api, $shape, $mode) = @$case;
    subtest "$api / $shape / $mode" => sub {
        my ($listen, $port) = get_listen_socket();
        die "listen: $!" unless $listen;
        setsockopt($listen, SOL_SOCKET, SO_SNDBUF, pack('i', 32768)) or die "SO_SNDBUF: $!";
        my $f = Feersum->new_instance;
        $f->use_socket($listen);
        $f->max_connections(1);
        $f->linger_timeout(0);
        $f->read_timeout(45 * TMULT);
        $f->write_timeout($wt);
        $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
        my $state = { body_closed => 0, gap_closed => 0, poll_closed => 0 };
        pipe(my $ready_r, my $ready_w) or die "pipe: $!";
        my $observed_server = $f;
        weaken($observed_server);
        my $inspect = sub {
            return unless $mode eq 'stalled';
            # inspect before the peer closes: a close behind queued DATA shows late
            $state->{inspection} = EV::timer(5 * $wt + 3 * TMULT, 0, sub {
                $state->{active_at_inspection} = $observed_server->active_conns;
                syswrite($ready_w, 'R');
            });
        };
        my $gap = sub {
            my $writer = shift;
            $state->{writer} = $writer;
            $writer->response_guard(guard {
                $state->{gap_closed}++;
                delete $state->{writer};
            });
            # no poll_cb: a write gap, not a source that declined an invitation
            $writer->write('Q');
        };
        my $poll = sub {
            my $writer = shift;
            my $left = $size;
            $state->{writer} = $writer;
            $writer->response_guard(guard {
                $state->{poll_closed}++;
                delete $state->{writer};
            });
            $writer->poll_cb(sub {
                my $ready_writer = shift;
                my $n = $left < 16384 ? $left : 16384;
                $left -= $n;
                $ready_writer->write('D' x $n);
                $ready_writer->close unless $left;
            });
        };
        if ($api eq 'native') {
            $f->request_handler(sub {
                my $req = shift;
                if ($req->path eq '/blocked') { $req->send_response(200, [], 'blocked'); return }
                if ($req->path eq '/gap') { $gap->($req->start_streaming(200, [])); return }
                $inspect->();
                if ($shape eq 'poll') { $poll->($req->start_streaming(200, [])); return }
                if ($shape eq 'writer') {
                    my $writer = $req->start_streaming(200, []);
                    $writer->write('D' x $size);
                    $writer->close;
                } else { $req->send_response(200, [], 'D' x $size) }
            });
        } else {
            $f->psgi_request_handler(sub {
                my $env = shift;
                return [200, [], ['blocked']] if $env->{PATH_INFO} eq '/blocked';
                return sub { $gap->(shift->([200, []])) } if $env->{PATH_INFO} eq '/gap';
                $inspect->();
                return sub { $poll->(shift->([200, []])) } if $shape eq 'poll';
                if ($shape eq 'writer') {
                    return sub {
                        my $writer = shift->([200, []]);
                        $writer->write('D' x $size);
                        $writer->close;
                    };
                }
                if ($shape eq 'io') {
                    return [200, [], bless({ left => $size, state => $state, env => $env }, 'LargeProgressBody')];
                }
                return [200, [], ['D' x $size]];
            });
        }
        run_client 'transport progress preserves only sendable buffered output', sub {
            local $SIG{ALRM} = sub { die "client timeout\n" };
            alarm 40 * TMULT;   # a 20x-slow smoker (armv6l) needs time to read 18MB
            # pin the receive buffer before connect (post-connect does not stop
            # macOS autosizing); the 18MB body already exceeds any autosized buffer
            my $sock = h2_connect($port, timeout => 3 * TMULT, rcvbuf => 32768) or return 10;
            my $cleanup = guard { close $sock };
            my $mixed = $mode eq 'mixed';
            my $batch = h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, $mixed ? 0 : $window))
                . h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $window)) . headers(1, '/large');
            if ($mixed) {
                $batch .= h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', $window))
                    . headers(3, '/blocked') . headers(5, '/gap')
                    . h2_frame(H2_WINDOW_UPDATE, 0, 5, pack('N', $window));
            }
            return 12 unless $sock->syswrite($batch) == length($batch);
            if ($mode eq 'stalled') {
                h2_read_until($sock, H2_HEADERS, 1, 3 * TMULT) or return 13;
                return 14 unless sysread($ready_r, my $ready, 1) == 1;
                alarm 0;
                return 0;
            }
            my ($buf, $body, $ended, $status, $quiet_bytes) = ('', 0, 0, 0, 0);
            my %reset;
            my $start = time;
            while (time - $start < 36 * TMULT) {
                if ($body > $pace * (time - $start)) {
                    select undef, undef, undef, 0.01;
                    next;
                }
                my $n = $sock->sysread(my $part, 65536);
                last if defined($n) && $n == 0;
                $buf .= $part if $n;
                while (length($buf) >= 9) {
                    my ($hi, $lo, $type, $flags, $id) = unpack('CnCCN', $buf);
                    my $len = ($hi << 16) | $lo;
                    last if length($buf) < 9 + $len;
                    my $frame = substr($buf, 0, 9 + $len, '');
                    return 15 if $type == H2_GOAWAY;
                    if ($type == H2_RST_STREAM) {
                        warn "large stream reset after $body/$size bytes\n" if $id == 1;
                        return 16 unless $mixed && ($id == 3 || $id == 5)
                            && unpack('N', substr($frame, 9)) == 8;
                        # a sibling's progress must not defer the zero-window reset
                        return 21 if $id == 3 && $ended;
                        $reset{$id} = 1;
                        next;
                    }
                    return 17 if $id == 3 && $type == H2_DATA;
                    $quiet_bytes += $len if $id == 5 && $type == H2_DATA;
                    next unless $id == 1;
                    $status = hpack_decode_status(substr($frame, 9)) if $type == H2_HEADERS;
                    if ($type == H2_DATA) {
                        return 18 unless substr($frame, 9) eq 'D' x $len;
                        $body += $len;
                    }
                    $ended = 1 if ($type == H2_DATA || $type == H2_HEADERS) && ($flags & FLAG_END_STREAM);
                }
                last if $ended && (!$mixed || ($reset{3} && $reset{5}));
                # one TLS record per read; sleeping after each capped BSD at ~400KB/s
                select undef, undef, undef, 0.001 * TMULT unless $n;
            }
            alarm 0;
            warn sprintf "body=%d/%d ended=%d status=%d resets=%s\n", $body, $size, $ended,
                $status, join(',', sort keys %reset) unless $ended && $status == 200 && $body == $size;
            return 19 unless $ended && $status == 200 && $body == $size && time - $start > $wt;
            return 20 if $mixed && (!$reset{3} || !$reset{5} || $quiet_bytes != 1);
            return 0;
        };
        delete $state->{inspection};
        is $state->{active_at_inspection}, 0, 'non-reading peer released admission before client closure'
            if $mode eq 'stalled';
        my $cv = AE::cv;
        my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
        $f->graceful_shutdown(sub { $cv->send(1) });
        ok $cv->recv, 'shutdown completed';
        is $state->{body_closed}, $shape eq 'io' ? 1 : 0, 'IO body cleanup ran exactly when required';
        is $state->{gap_closed}, $mode eq 'mixed' ? 1 : 0, 'timed-out writer cleanup ran exactly once';
        is $state->{poll_closed}, $shape eq 'poll' ? 1 : 0, 'polled writer cleanup ran exactly once';
        ok !exists $state->{writer}, 'no application writer retained';
        is $f->active_conns, 0, 'no sockets or streams retained';
        done_testing;
    };
}
done_testing;
