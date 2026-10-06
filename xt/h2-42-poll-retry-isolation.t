#!perl
# Peer traffic must not re-invite a declined source, including one with a
# flow-controlled low-water tail. Real output progress still resumes it.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use IO::Socket::INET;
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

sub headers {
    my ($id, $path) = @_;
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $id,
        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', 'x'], [':path', $path]));
}

sub read_reply {
    my ($sock, $id, $status) = @_;
    $status //= 0;
    my ($body, $ended) = ('', 0);
    my $deadline = time + 3 * TMULT;
    while (time < $deadline && !$ended) {
        my $frame = h2_read_frame($sock, 0.1) or next;
        return undef if $frame->{type} == H2_GOAWAY;
        next unless $frame->{stream_id} == $id;
        return undef if $frame->{type} == H2_RST_STREAM;
        $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
        $body .= $frame->{payload} if $frame->{type} == H2_DATA;
        $ended = 1 if ($frame->{type} == H2_DATA || $frame->{type} == H2_HEADERS)
            && ($frame->{flags} & FLAG_END_STREAM);
    }
    return $ended && $status == 200 ? $body : undef;
}

sub count_invites {
    my ($port, $path) = @_;
    $path //= '/count';
    my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
        or die "count connect: $!";
    $sock->syswrite("GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    my $raw = '';
    while ($sock->sysread(my $part, 4096)) { $raw .= $part }
    close $sock;
    $raw =~ /\r\n\r\n(\d+)\z/ or die "invalid count response: $raw";
    return $1;
}

sub setup_server {
    my ($api, $timeout, $initial, $producer, $low_water) = @_;
    my ($plain, $plain_port) = get_listen_socket();
    my ($tls, $tls_port) = get_listen_socket();
    die "listen: $!" unless $plain && $tls;
    my $f = Feersum->new_instance;
    $f->use_socket($plain);
    $f->use_socket($tls);
    $f->set_tls(listener => 1, cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->linger_timeout(0);
    $f->read_timeout(30 * TMULT);
    $f->write_timeout($timeout);
    $f->wbuf_low_water($low_water) if defined $low_water;
    my $state = { invites => 0, closed => 0, events => 0 };
    my $start = sub {
        my $writer = shift;
        $state->{writer} = $writer;
        $writer->response_guard(guard {
            $state->{closed}++;
            delete $state->{timer};
            delete $state->{writer};
        });
        $writer->write($initial);
        $writer->poll_cb(sub {
            my $ready_writer = shift;
            $state->{invites}++;
            if ($state->{ready}) {
                $ready_writer->write('done');
                $ready_writer->close;
            }
            return;
        });
        $producer->($writer, $state) if $producer;
    };
    if ($api eq 'psgi') {
        $f->psgi_request_handler(sub {
            my $env = shift;
            return sub { $start->(shift->([200, []])) } if $env->{PATH_INFO} eq '/quiet';
            $state->{ready} = 1 if $env->{PATH_INFO} eq '/finish';
            return [200, [], [$env->{PATH_INFO} =~ m{\A/(?:count|finish)\z}
                ? "$state->{invites}" : 'OK']];
        });
    } else {
        $f->request_handler(sub {
            my $req = shift;
            if ($req->path eq '/quiet') { $start->($req->start_streaming(200, [])) }
            else {
                $state->{ready} = 1 if $req->path eq '/finish';
                $req->send_response(200, [], $req->path =~ m{\A/(?:count|finish)\z}
                    ? "$state->{invites}" : 'OK');
            }
        });
    }
    # use_socket keeps the listening socket objects alive.
    return ($f, $plain_port, $tls_port, $state);
}

sub check_cleanup {
    my ($f, $state) = @_;
    my $cv = AE::cv;
    my $deadline = AE::timer(2 * TMULT, 0, sub { $cv->send(0) });
    $f->graceful_shutdown(sub { $cv->send(1) });
    ok $cv->recv, 'shutdown completed after response cleanup';
    is $state->{closed}, 1, 'the response guard fired exactly once';
    ok !exists $state->{writer} && !exists $state->{timer}, 'producer resources released';
    is $f->active_conns, 0, 'no sockets or streams retained';
}

for my $api ('native', 'psgi') {
    for my $timeout (0, 0.4 * TMULT) {
        for my $traffic ('ping', 'window update', 'sibling replies', 'low-water tail') {
            my $tail = $traffic eq 'low-water tail';
            my $effective_timeout = $tail && $timeout > 0 ? 3 * TMULT : $timeout;
            subtest "$api / write_timeout=$effective_timeout / $traffic" => sub {
                my ($f, $plain_port, $tls_port, $state) = setup_server(
                    $api, $effective_timeout, 'parked', undef, $tail ? 1024 : 0);
                run_client 'unrelated peer traffic preserves callback pacing', sub {
                    local $SIG{ALRM} = sub { die "client timeout\n" };
                    alarm 12 * TMULT;
                    my $sock = h2_connect($tls_port, timeout => 3 * TMULT) or return 10;
                    my $cleanup = guard {
                        eval { $sock->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 8))) };
                        close $sock;
                    };
                    $sock->syswrite(($tail ? h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 0)) : '')
                        . headers(1, '/quiet'));
                    my $first = h2_read_until($sock, $tail ? H2_HEADERS : H2_DATA, 1, 3 * TMULT)
                        or return 11;
                    return 12 unless $tail ? hpack_decode_status($first->{payload}) == 200
                        : $first->{payload} eq 'parked';
                    # reach the 100 ms retry plateau; stats use the plain listener
                    select undef, undef, undef, 0.3 * TMULT;
                    my $start = time;
                    my $before = count_invites($plain_port);
                    my $frames = $traffic eq 'sibling replies' ? 80 : 200;
                    for my $i (1 .. $frames) {
                        if ($traffic eq 'sibling replies') {
                            my $id = 2 * $i + 1;
                            $sock->syswrite(headers($id, '/side'));
                            my $body = read_reply($sock, $id);
                            return 13 unless defined($body) && $body eq 'OK';
                        } else {
                            my $frame = $traffic eq 'ping'
                                ? h2_frame(H2_PING, 0, 0, pack('NN', 0, $i))
                                : h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', 1));
                            return 14 unless $sock->syswrite($frame) == length($frame);
                            # drain PING ACKs: this is not a non-reading-peer flood test
                            $sock->sysread(my $part, 65536);
                            select undef, undef, undef, 0.001 * TMULT;
                        }
                    }
                    select undef, undef, undef, 0.05 * TMULT;
                    my $after = count_invites($plain_port);
                    my $elapsed = time - $start;
                    my $allowed = 12 + int($elapsed / 0.1);
                    my $extra = $after - $before;
                    warn sprintf "extra invites=%d allowed=%d elapsed=%.2f\n", $extra, $allowed, $elapsed
                        if $extra > $allowed;
                    return 15 if $extra > $allowed;
                    if ($tail) {
                        # only a stream-window release, not readiness, drains the tail
                        count_invites($plain_port, '/finish');
                        $sock->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', 65535)));
                        my $body = read_reply($sock, 1, 200);
                        return 16 unless defined($body) && $body eq 'parkeddone';
                    }
                    alarm 0;
                    return 0;
                };
                check_cleanup($f, $state);
                done_testing;
            };
        }
    }
    for my $timeout (0, 0.1 * TMULT) {
        subtest "$api / write_timeout=$timeout / external events" => sub {
            my $producer = sub {
                my ($writer, $state) = @_;
                $state->{timer} = EV::timer(0.35 * TMULT, 0.35 * TMULT, sub {
                    if (++$state->{events} < 3) {
                        $writer->write("event$state->{events}|");
                    } else {
                        $writer->write('done');
                        $writer->close;
                    }
                });
            };
            my ($f, $plain_port, $tls_port, $state) = setup_server($api, $timeout, 'start|', $producer);
            run_client 'quiet source survives multiple asynchronous events', sub {
                local $SIG{ALRM} = sub { die "client timeout\n" };
                alarm 8 * TMULT;
                my $sock = h2_connect($tls_port, timeout => 3 * TMULT) or return 10;
                my $cleanup = guard {
                    eval { $sock->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 8))) };
                    close $sock;
                };
                $sock->syswrite(headers(1, '/quiet'));
                my $body = read_reply($sock, 1);
                warn 'incomplete asynchronous response: ' . (defined($body) ? $body : '<reset>') . "\n"
                    unless defined($body) && $body eq 'start|event1|event2|done';
                alarm 0;
                return defined($body) && $body eq 'start|event1|event2|done' ? 0 : 11;
            };
            is $state->{events}, 3, 'every source event ran despite gaps longer than write_timeout';
            check_cleanup($f, $state);
            done_testing;
        };
    }
}
done_testing;
