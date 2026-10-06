#!perl
# Finishing a busy keepalive reply must wake listeners paused at capacity,
# even while the completed socket remains open and needs eviction.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use IO::Socket::INET;
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
my $probe = Feersum->new_instance;
my $tls_ok = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

sub headers {
    my ($path) = @_;
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', 'x'], [':path', $path]));
}

sub connect_client {
    my ($port, $transport) = @_;
    return h2_connect($port, timeout => 3 * TMULT) if $transport eq 'h2';
    return IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT,
        SSL_verify_mode => 0, SSL_alpn_protocols => ['http/1.1']) if $transport eq 'tls';
    return IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT);
}

sub read_reply {
    my ($sock, $transport, $want) = @_;
    my ($body, $status, $ended) = ('', 0, 0);
    if ($transport eq 'h2') {
        my $deadline = time + 3 * TMULT;
        while (time < $deadline) {
            my $frame = h2_read_frame($sock, 0.1) or next;
            return 0 if $frame->{type} == H2_GOAWAY || $frame->{type} == H2_RST_STREAM;
            next unless $frame->{stream_id} == 1;
            $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
            $body .= $frame->{payload} if $frame->{type} == H2_DATA;
            if ($frame->{flags} & FLAG_END_STREAM) { $ended = 1; last }
        }
        return $status == 200 && $ended && $body eq $want;
    }
    my $raw = '';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "reply timeout\n" };
        alarm 3 * TMULT;
        while (1) {
            my $n = $sock->sysread(my $part, 65536);
            last unless $n;
            $raw .= $part;
            my $end = index($raw, "\r\n\r\n");
            next if $end < 0;
            last if $raw =~ /\r\nContent-Length: (\d+)\r\n/i
                && length($raw) - $end - 4 >= $1;
        }
        alarm 0;
        1;
    };
    alarm 0;
    return $ok && $raw =~ m{^HTTP/1\.1 200 .*\r\n\r\n\Q$want\E\z}s;
}

for my $api ('native', 'psgi') {
    for my $transport ('plain', 'tls', 'h2', 'user pause') {
        subtest "$api / $transport" => sub {
            plan skip_all => 'TLS unavailable' if $transport eq 'tls' && !$tls_ok;
            plan skip_all => 'TLS/H2 unavailable' if $transport eq 'h2' && !($tls_ok && $probe->has_h2);
            my $user_pause = $transport eq 'user pause';
            my $wire = $user_pause ? 'plain' : $transport;
            my ($listen, $port) = get_listen_socket();
            die "listen: $!" unless $listen;
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->set_keepalive(1);
            $f->max_connections(1);
            $f->linger_timeout(0);
            $f->read_timeout(30 * TMULT);
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
                h2 => $wire eq 'h2') if $wire ne 'plain';
            pipe(my $ready_r, my $ready_w) or die "pipe: $!";
            pipe(my $rejected_r, my $rejected_w) or die "pipe: $!";
            pipe(my $resume_r, my $resume_w) or die "pipe: $!";
            my ($pending, $saw_cap, $still_paused, @paths);
            if ($api eq 'psgi') {
                $f->psgi_request_handler(sub {
                    my $env = shift;
                    push @paths, $env->{PATH_INFO};
                    return [200, [], ['probe']] unless $env->{PATH_INFO} eq '/held';
                    return sub {
                        my $respond = shift;
                        $pending = sub { $respond->([200, [], ['held']]) };
                        syswrite($ready_w, 'R');
                    };
                });
            } else {
                $f->request_handler(sub {
                    my $req = shift;
                    push @paths, $req->env->{PATH_INFO};
                    if ($paths[-1] eq '/held') {
                        $pending = sub { $req->send_response(200, [], 'held') };
                        syswrite($ready_w, 'R');
                    } else { $req->send_response(200, [], 'probe') }
                });
            }
            # reply only after the excess socket is rejected, i.e. paused at capacity
            my $gate = EV::io(fileno($rejected_r), EV::READ, sub {
                sysread($rejected_r, my $byte, 1);
                return unless $pending;
                $saw_cap = 1;
                $f->pause_accept if $user_pause;
                my $send = $pending;
                undef $pending;
                $send->();
            });
            my $resume;
            $resume = EV::io(fileno($resume_r), EV::READ, sub {
                sysread($resume_r, my $byte, 1);
                $still_paused = $f->accept_is_paused;
                $f->resume_accept;
            }) if $user_pause;

            run_client 'busy socket becomes idle, then a replacement arrives', sub {
                local $SIG{ALRM} = sub { die "client timeout\n" };
                alarm 12 * TMULT;
                my $old = connect_client($port, $wire) or return 10;
                $old->syswrite($wire eq 'h2' ? headers('/held')
                    : "GET /held HTTP/1.1\r\nHost: x\r\n\r\n");
                return 11 unless sysread($ready_r, my $ready, 1) == 1;
                my $over = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 2 * TMULT)
                    or return 12;
                syswrite($over, "GET /over HTTP/1.1\r\nHost: x\r\n\r\n");
                my $n = sysread($over, my $rejected, 65536);
                return 13 if $n;
                close $over;
                syswrite($rejected_w, 'C');
                return 14 unless read_reply($old, $wire, 'held');
                my $fresh = connect_client($port, $wire) or return 15;
                $fresh->syswrite($wire eq 'h2' ? headers('/probe')
                    : "GET /probe HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
                if ($user_pause) {
                    $fresh->blocking(0);
                    my $deadline = time + 0.15 * TMULT;
                    while (time < $deadline) {
                        return 16 if sysread($fresh, my $part, 65536);
                        select undef, undef, undef, 0.01;
                    }
                    syswrite($resume_w, 'U');
                    $fresh->blocking(1);
                }
                return 17 unless read_reply($fresh, $wire, 'probe');
                close $fresh;
                close $old;
                alarm 0;
                return 0;
            };
            undef $gate;
            undef $resume;
            ok $saw_cap, 'excess connection triggered the capacity pause';
            ok $still_paused, 'becoming idle preserved the explicit user pause' if $user_pause;
            is_deeply \@paths, ['/held', '/probe'], 'only the two admitted requests ran';
            my $cv = AE::cv;
            my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
            $f->graceful_shutdown(sub { $cv->send(1) });
            ok $cv->recv, 'all connections released and graceful shutdown completed';
            is $f->active_conns, 0, 'no admission slots retained';
            done_testing;
        };
    }
}
done_testing;
