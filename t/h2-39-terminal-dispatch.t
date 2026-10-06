#!perl
# A fatal connection frame can terminate nghttp2 after requests have been
# queued. Linger keeps their stream objects alive, but cannot send replies.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

sub headers {
    my ($id, $path, $kind) = @_;
    $kind //= 'get';
    my @headers = ([':method', $kind eq 'connect' ? 'CONNECT' : $kind eq 'get' ? 'GET' : 'POST'],
        [':scheme', 'https'], [':authority', 'x'], [':path', $path]);
    push @headers, [':protocol', 'websocket'] if $kind eq 'connect';
    push @headers, ['content-length', 4] if $kind eq 'body' || $kind eq 'trailers';
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | ($kind eq 'get' ? FLAG_END_STREAM : 0),
        $id, hpack_encode_headers(@headers));
}

sub read_responses {
    my ($sock, @ids) = @_;
    my %want = map { $_ => 1 } @ids;
    my (%status, %body, %ended);
    my $deadline = time + 3 * TMULT;
    while (time < $deadline && keys(%ended) < @ids) {
        my $frame = h2_read_frame($sock, 0.1) or next;
        return undef if $frame->{type} == H2_RST_STREAM && $want{$frame->{stream_id}};
        my $id = $frame->{stream_id};
        next unless $want{$id};
        $status{$id} = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
        $body{$id} .= $frame->{payload} if $frame->{type} == H2_DATA;
        $ended{$id} = 1 if ($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
            && ($frame->{flags} & FLAG_END_STREAM);
    }
    return undef unless keys(%ended) == @ids && !grep { ($status{$_} // 0) != 200 } @ids;
    return \%body;
}

my @cases = (
    ['settings on stream one', h2_frame(H2_SETTINGS, 0, 1, ''), 0.3 * TMULT],
    ['short ping', h2_frame(H2_PING, 0, 0, '1234567'), 0.3 * TMULT],
    ['data on stream zero', h2_frame(H2_DATA, 0, 0, 'x'), 0.3 * TMULT],
    ['zero window increment', h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', 0)), 0.3 * TMULT],
    ['immediate close', h2_frame(H2_SETTINGS, 0, 1, ''), 0],
    ['ordinary client GOAWAY', h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)), 0.3 * TMULT, 1],
);

for my $api ('psgi', 'native') {
    subtest $api => sub {
        for my $case (@cases) {
            my ($label, $tail, $linger, $normal) = @$case;
            subtest $label => sub {
                my ($listen, $port) = get_listen_socket();
                die "listen: $!" unless $listen;
                my $f = Feersum->new_instance;
                $f->use_socket($listen);
                $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
                $f->linger_timeout($linger);
                my (@paths, $retired);
                $f->max_requests_per_worker(2, sub { $retired++ }) unless $normal;
                if ($api eq 'psgi') {
                    $f->psgi_request_handler(sub {
                        my $env = shift;
                        push @paths, $env->{PATH_INFO};
                        return [200, [], [$env->{PATH_INFO}]];
                    });
                } else {
                    $f->request_handler(sub {
                        my $req = shift;
                        my $path = $req->env->{PATH_INFO};
                        push @paths, $path;
                        $req->send_response(200, [], $path);
                    });
                }

                run_client 'queued requests followed by a connection frame', sub {
                    my $sock = h2_connect($port) or return 10;
                    my $batch;
                    if ($normal) {
                        $batch = headers(1, '/before') . headers(3, '/after');
                    } else {
                        $batch = headers(1, '/lost-get') . headers(3, '/lost-body', 'body')
                            . h2_frame(H2_DATA, FLAG_END_STREAM, 3, 'data')
                            . headers(5, '/lost-trailers', 'trailers')
                            . h2_frame(H2_DATA, 0, 5, 'data')
                            . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 5,
                                hpack_encode_headers(['x-check', 'done']))
                            . headers(7, '/lost-connect', 'connect');
                    }
                    # one TLS record, so nghttp2 sees the fatal frame before dispatch
                    $batch .= $tail;
                    return 11 unless $sock->syswrite($batch) == length($batch);
                    if ($normal) {
                        my $bodies = read_responses($sock, 1, 3);
                        return 12 unless $bodies && ($bodies->{1} // '') eq '/before'
                            && ($bodies->{3} // '') eq '/after';
                    } else {
                        my $goaway = h2_read_until($sock, H2_GOAWAY, 0, 3 * TMULT);
                        return 13 unless $goaway && length($goaway->{payload}) >= 8
                            && unpack('N', substr($goaway->{payload}, 4, 4)) != 0;
                    }
                    $sock->close;

                    my $fresh = h2_connect($port) or return 14;
                    $batch = headers(1, '/probe');
                    return 15 unless $fresh->syswrite($batch) == length($batch);
                    my $bodies = read_responses($fresh, 1);
                    return 16 unless $bodies && ($bodies->{1} // '') eq '/probe';
                    $fresh->close;
                    return 0;
                };

                my @expected = $normal ? ('/before', '/after', '/probe') : ('/probe');
                is_deeply \@paths, \@expected, 'only requests with a response path reach the handler';
                is $f->total_requests, scalar @expected, 'terminal requests do not spend retirement allowance';
                is $retired // 0, 0, 'a protocol error does not retire the worker';
                if ($f->active_conns) {
                    my $cv = AE::cv;
                    my $deadline = time + 1 * TMULT;
                    my $wait = AE::timer(0, 0.01, sub {
                        $cv->send if !$f->active_conns || time >= $deadline;
                    });
                    $cv->recv;
                }
                is $f->active_conns, 0, 'terminal and healthy connections release their objects';
                my $drained = 0;
                my $drain_ok = eval { $f->graceful_shutdown(sub { $drained++ }); 1 };
                ok $drain_ok && $drained == 1, 'the worker can still drain normally';
                done_testing;
            };
        }
        done_testing;
    };
}
done_testing;
