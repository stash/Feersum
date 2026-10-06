#!perl
# Raising or disabling max_connections must release a capacity pause without
# waiting for a live delayed response to finish. User pauses still apply.
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

sub connect_client {
    my ($port, $wire) = @_;
    return h2_connect($port, timeout => 3 * TMULT) if $wire eq 'h2';
    return IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT,
        SSL_verify_mode => 0, SSL_alpn_protocols => ['http/1.1']) if $wire eq 'tls';
    return IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT);
}

sub send_get {
    my ($sock, $wire, $path) = @_;
    return $sock->syswrite($wire eq 'h2'
        ? h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
            hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                [':authority', 'x'], [':path', $path]))
        : "GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
}

sub read_reply {
    my ($sock, $wire, $want) = @_;
    if ($wire eq 'h2') {
        my ($status, $body, $ended) = (0, '', 0);
        my $deadline = time + 3 * TMULT;
        while (time < $deadline && !$ended) {
            my $frame = h2_read_frame($sock, 0.1) or next;
            return 0 if $frame->{type} == H2_GOAWAY || $frame->{type} == H2_RST_STREAM;
            next unless $frame->{stream_id} == 1;
            $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
            $body .= $frame->{payload} if $frame->{type} == H2_DATA;
            $ended = 1 if ($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
                && ($frame->{flags} & FLAG_END_STREAM);
        }
        return $status == 200 && $ended && $body eq $want;
    }
    my $raw = '';
    my $ok = eval {
        local $SIG{ALRM} = sub { die "reply timeout\n" };
        alarm 3 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        1;
    };
    alarm 0;
    return $ok && $raw =~ m{\AHTTP/1\.1 200 .*\r\n\r\n\Q$want\E\z}s;
}

for my $api ('native', 'psgi') {
    for my $new_limit (2, 0) {
        for my $transport ('plain', 'tls', 'h2', 'user pause') {
            subtest "$api / limit $new_limit / $transport" => sub {
                plan skip_all => 'TLS unavailable' if $transport eq 'tls' && !$tls_ok;
                plan skip_all => 'TLS/H2 unavailable' if $transport eq 'h2' && !($tls_ok && $probe->has_h2);
                my $user_pause = $transport eq 'user pause';
                my $wire = $user_pause ? 'plain' : $transport;
                my ($listen, $port) = get_listen_socket();
                die "listen: $!" unless $listen;
                my $f = Feersum->new_instance;
                $f->use_socket($listen);
                $f->max_connections(1);
                $f->linger_timeout(0);
                $f->read_timeout(30 * TMULT);
                $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
                    h2 => $wire eq 'h2') if $wire ne 'plain';
                pipe(my $ready_r, my $ready_w) or die "pipe: $!";
                pipe(my $change_r, my $change_w) or die "pipe: $!";
                my ($pending, $fallback, $changed_while_busy, $set_value, $still_paused, @paths);
                my $finish_held = sub {
                    my $send = $pending;
                    undef $pending;
                    $send->() if $send;
                };
                my $hold = sub {
                    $pending = shift;
                    syswrite($ready_w, 'R');
                    $fallback = EV::timer(8 * TMULT, 0, $finish_held);
                };
                if ($api eq 'psgi') {
                    $f->psgi_request_handler(sub {
                        my $env = shift;
                        push @paths, $env->{PATH_INFO};
                        if ($paths[-1] eq '/held') {
                            return sub {
                                my $respond = shift;
                                $hold->(sub { $respond->([200, [], ['held']]) });
                            };
                        }
                        $finish_held->();
                        return [200, [], ['probe']];
                    });
                } else {
                    $f->request_handler(sub {
                        my $req = shift;
                        push @paths, $req->env->{PATH_INFO};
                        if ($paths[-1] eq '/held') {
                            $hold->(sub { $req->send_response(200, [], 'held') });
                        } else {
                            $finish_held->();
                            $req->send_response(200, [], 'probe');
                        }
                    });
                }
                my $change = EV::io(fileno($change_r), EV::READ, sub {
                    sysread($change_r, my $byte, 1);
                    if ($byte eq 'C') {
                        $changed_while_busy = defined $pending;
                        $f->pause_accept if $user_pause;
                        $set_value = $f->max_connections($new_limit);
                    } else {
                        $still_paused = $f->accept_is_paused;
                        $f->resume_accept;
                    }
                    syswrite($ready_w, 'M');
                });
                run_client 'limit change admits a request before the busy reply finishes', sub {
                    local $SIG{ALRM} = sub { die "client timeout\n" };
                    alarm 12 * TMULT;
                    my $old = connect_client($port, $wire) or return 10;
                    send_get($old, $wire, '/held');
                    return 11 unless sysread($ready_r, my $ready, 1) == 1;
                    my $over = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 2 * TMULT)
                        or return 12;
                    send_get($over, 'plain', '/over');
                    return 13 if sysread($over, my $rejected, 1024);
                    close $over;
                    syswrite($change_w, 'C');
                    return 14 unless sysread($ready_r, $ready, 1) == 1;
                    my $fresh = connect_client($port, $wire) or return 15;
                    send_get($fresh, $wire, '/probe');
                    if ($user_pause) {
                        $fresh->blocking(0);
                        my $deadline = time + 0.15 * TMULT;
                        while (time < $deadline) {
                            return 16 if $fresh->sysread(my $part, 1024);
                            select undef, undef, undef, 0.01;
                        }
                        syswrite($change_w, 'U');
                        return 17 unless sysread($ready_r, $ready, 1) == 1;
                        $fresh->blocking(1);
                    }
                    return 18 unless read_reply($fresh, $wire, 'probe');
                    return 19 unless read_reply($old, $wire, 'held');
                    close $fresh;
                    close $old;
                    alarm 0;
                    return 0;
                };
                undef $fallback;
                $finish_held->();
                undef $change;
                ok $changed_while_busy, 'the original request was still awaiting its response';
                is $set_value, $new_limit, 'the runtime setter applied the new limit';
                ok $still_paused, 'the limit change preserved the explicit user pause' if $user_pause;
                is_deeply \@paths, ['/held', '/probe'], 'only admitted requests reached the handler';
                my $cv = AE::cv;
                my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
                $f->graceful_shutdown(sub { $cv->send(1) });
                ok $cv->recv, 'connections released and shutdown completed';
                is $f->active_conns, 0, 'no admission slots retained';
                done_testing;
            };
        }
    }
}
done_testing;
