#!perl
# A request cancelled while still queued must not start application work;
# headers, bodies, trailers and Extended CONNECT all dispatch via that queue.
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
    my $flags = FLAG_END_HEADERS | ($kind eq 'get' ? FLAG_END_STREAM : 0);
    return h2_frame(H2_HEADERS, $flags, $id, hpack_encode_headers(@headers));
}

sub read_responses {
    my ($sock, @ids) = @_;
    my %want = map { $_ => 1 } @ids;
    my (%status, %body, %ended);
    my $deadline = time + 3 * TMULT;
    while (time < $deadline && keys(%ended) < @ids) {
        my $frame = h2_read_frame($sock, 0.1) or next;
        return undef if $frame->{type} == H2_GOAWAY;
        my $id = $frame->{stream_id};
        next unless $want{$id};
        return undef if $frame->{type} == H2_RST_STREAM;
        $status{$id} = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
        $body{$id} .= $frame->{payload} if $frame->{type} == H2_DATA;
        $ended{$id} = 1 if ($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
            && ($frame->{flags} & FLAG_END_STREAM);
    }
    return undef unless keys(%ended) == @ids && !grep { ($status{$_} // 0) != 200 } @ids;
    return \%body;
}

for my $api ('psgi', 'native') {
    subtest $api => sub {
        my ($listen, $port) = get_listen_socket();
        die "listen: $!" unless $listen;
        my $f = Feersum->new_instance;
        $f->use_socket($listen);
        $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
        $f->max_h2_concurrent_streams(2);
        $f->linger_timeout(0);
        my (@dispatched, @late_errors);
        my ($pending, $late_replies);
        my $record = sub {
            my $env = shift;
            push @dispatched, $env->{PATH_INFO};
            return $env->{PATH_INFO};
        };
        if ($api eq 'psgi') {
            $f->psgi_request_handler(sub {
                my $path = $record->(shift);
                if ($path eq '/late') {
                    return sub {
                        my $responder = shift;
                        $pending = sub { $responder->([200, [], ['late reply']]) };
                    };
                }
                if ($path eq '/release' && $pending) {
                    my $reply = $pending;
                    $pending = undef;
                    eval { $reply->(); 1 } or push @late_errors, $@;
                    $late_replies++;
                }
                return [200, [], [$path]];
            });
        } else {
            $f->request_handler(sub {
                my $req = shift;
                my $path = $record->($req->env);
                if ($path eq '/late') {
                    $pending = sub { $req->send_response(200, [], 'late reply') };
                    return;
                }
                if ($path eq '/release' && $pending) {
                    my $reply = $pending;
                    $pending = undef;
                    eval { $reply->(); 1 } or push @late_errors, $@;
                    $late_replies++;
                }
                $req->send_response(200, [], $path);
            });
        }

        run_client 'queued requests cancelled beside healthy siblings', sub {
            my $sock = h2_connect($port) or return 10;
            my $batch = headers(1, '/before');
            my $id = 3;
            for my $round (1 .. 3) {
                for my $kind ('get', 'body', 'trailers', 'connect') {
                    $batch .= headers($id, "/cancel-$kind-$round", $kind);
                    $batch .= h2_frame(H2_DATA, FLAG_END_STREAM, $id, 'data') if $kind eq 'body';
                    if ($kind eq 'trailers') {
                        $batch .= h2_frame(H2_DATA, 0, $id, 'data')
                            . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $id,
                                hpack_encode_headers(['x-check', 'done']));
                    }
                    $batch .= h2_frame(H2_RST_STREAM, 0, $id, pack('N', $round == 2 ? 0 : 8));
                    $id += 2;
                }
            }
            $batch .= headers($id, '/after');
            # one write: each completion and its reset share a TLS record
            return 11 unless $sock->syswrite($batch) == length($batch);
            my $responses = read_responses($sock, 1, $id);
            return 12 unless $responses && ($responses->{1} // '') eq '/before'
                && ($responses->{$id} // '') eq '/after';
            $id += 2;
            my $request = headers($id, '/probe');
            return 13 unless $sock->syswrite($request) == length($request);
            $responses = read_responses($sock, $id);
            return 14 unless $responses && ($responses->{$id} // '') eq '/probe';

            # /started proves /late dispatched; its reset shares a record with /release
            my $late_id = $id + 2;
            my $started_id = $late_id + 2;
            $request = headers($late_id, '/late') . headers($started_id, '/started');
            return 15 unless $sock->syswrite($request) == length($request);
            $responses = read_responses($sock, $started_id);
            return 16 unless $responses && ($responses->{$started_id} // '') eq '/started';
            my $release_id = $started_id + 2;
            $request = h2_frame(H2_RST_STREAM, 0, $late_id, pack('N', 8))
                . headers($release_id, '/release');
            return 17 unless $sock->syswrite($request) == length($request);
            $responses = read_responses($sock, $release_id);
            return 18 unless $responses && ($responses->{$release_id} // '') eq '/release';
            $sock->close;
            return 0;
        };

        is_deeply \@dispatched, ['/before', '/after', '/probe', '/late', '/started', '/release'],
            'only live requests start application callbacks';
        is $f->total_requests, 6, 'cancelled queued requests do not count as application requests';
        is $late_replies, 1, 'a response delayed after dispatch can still finish after cancellation';
        is_deeply \@late_errors, [], 'late replies to cancelled streams remain harmless';
        if ($f->active_conns) {
            my $cv = AE::cv;
            my $deadline = time + 1 * TMULT;
            my $wait = AE::timer(0, 0.01, sub {
                $cv->send if !$f->active_conns || time >= $deadline;
            });
            $cv->recv;
        }
        is $f->active_conns, 0, 'cancelled and completed streams release their connection objects';
        my $drained = 0;
        $f->graceful_shutdown(sub { $drained++ });
        is $drained, 1, 'cancellation does not prevent graceful shutdown';
        done_testing;
    };
}
done_testing;
