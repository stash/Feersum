#!perl
# Response guards may capture request metadata without retaining a Writer.
# Completing the response must break cycles through env -> psgi.input.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_LINGER);
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
my @transports = ('plain', 'plain-no-linger');
push @transports, 'tls' if $probe->has_tls
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
push @transports, 'h2' if @transports > 2 && $probe->has_h2;

sub connect_client {
    my ($transport, $port) = @_;
    return h2_connect($port) if $transport eq 'h2';
    return $transport eq 'tls'
        ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(), Timeout => 5 * TMULT)
        : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 5 * TMULT);
}

sub h2_request {
    my ($id, $path, $method) = @_;
    $method //= 'GET';
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $id,
        hpack_encode_headers([':method', $method], [':scheme', 'https'],
            [':authority', 'x'], [':path', $path]));
}

sub read_h2_response {
    my ($s, $id, $expected_status) = @_;
    $expected_status //= 200;
    my ($status, $body, $ended) = (0, '', 0);
    my $deadline = time + 5 * TMULT;
    while (time < $deadline && !$ended) {
        my $frame = h2_read_frame($s, 0.1) or next;
        next unless $frame->{stream_id} == $id;
        return undef if $frame->{type} == H2_RST_STREAM;
        $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
        $body .= $frame->{payload} if $frame->{type} == H2_DATA;
        $ended = 1 if ($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
            && ($frame->{flags} & FLAG_END_STREAM);
    }
    return $ended && $status == $expected_status ? $body : undef;
}

sub read_http_response {
    my ($s, $body_len, $expected_status) = @_;
    $expected_status //= 200;
    my $result;
    eval {
        local $SIG{ALRM} = sub { die "response timeout\n" };
        alarm 5 * TMULT;
        my $head = '';
        while ($head !~ /\r\n\r\n\z/) {
            die "missing headers\n" unless $s->sysread(my $byte, 1);
            $head .= $byte;
            die "oversized headers\n" if length($head) > 65536;
        }
        die "response status\n" unless $head =~ /\AHTTP\/1\.1 \Q$expected_status\E\b/;
        my $body = '';
        while (length($body) < $body_len) {
            die "missing body\n" unless $s->sysread(my $part, $body_len - length($body));
            $body .= $part;
        }
        $result = $body;
        alarm 0;
        1;
    } or alarm 0;
    return $result;
}

sub wait_for_close {
    my $f = shift;
    return unless $f->active_conns;
    my $cv = AE::cv;
    my $deadline = time + 1 * TMULT;
    my $wait = AE::timer(0, 0.01, sub {
        $cv->send if !$f->active_conns || time >= $deadline;
    });
    $cv->recv;
}

for my $transport (@transports) {
    subtest $transport => sub {
        my ($listen, $port) = get_listen_socket();
        die "listen: $!" unless $listen;
        my $f = Feersum->new_instance;
        $f->use_socket($listen);
        $f->set_keepalive(1);
        $f->linger_timeout(0) if $transport eq 'plain-no-linger';
        $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
                    h2 => $transport eq 'h2' ? 1 : 0) if $transport !~ /^plain/;
        my (@completed, @replacement, @cancelled_bytes, %writers);
        my $download_size = 64 * 1024 * 1024;
        $f->psgi_request_handler(sub {
            my $env = shift;
            return [200, [], [join(',', @completed)]] if $env->{PATH_INFO} eq '/probe';
            return sub {
                my $aborting = $env->{PATH_INFO} eq '/abort';
                my ($status) = $env->{PATH_INFO} =~ m{\A/status-(204|205|304)\z};
                my $writer = $_[0]->([$status // 200,
                    $status ? [] : ['Content-Length' => $aborting ? $download_size : 2]]);
                # the app retains the Writer; its guard must drop it on cancel
                $writers{$env->{PATH_INFO}} = $writer if $aborting;
                my $sent = 0;
                push @replacement, scalar @completed if $env->{PATH_INFO} eq '/keep-second';
                $writer->response_guard(guard {
                    push @completed, $env->{PATH_INFO};
                    push @cancelled_bytes, $sent if $aborting;
                    delete $writers{$env->{PATH_INFO}} if $aborting;
                });
                push @replacement, scalar @completed if $env->{PATH_INFO} eq '/keep-second';
                if ($aborting) {
                    $writer->poll_cb(sub {
                        my $w = shift;
                        my $n = $download_size - $sent;
                        $n = 32768 if $n > 32768;
                        # uses request metadata without retaining the passed Writer
                        $sent += $w->write(substr($env->{REQUEST_METHOD}, 0, 1) x $n);
                        $w->close if $sent == $download_size;
                    });
                    return;
                }
                $writer->write('OK');
                $writer->close;
            };
        });

        run_client 'guard captures request metadata', sub {
            for my $case (['GET', '/first', 200, 'OK'], ['GET', '/second', 200, 'OK'],
                    ['GET', '/third', 200, 'OK'], ['HEAD', '/head', 200, ''],
                    map { ['GET', "/status-$_", $_, ''] } (204, 205, 304)) {
                my ($method, $path, $status, $expected_body) = @$case;
                my $s = connect_client($transport, $port) or return 10;
                if ($transport eq 'h2') {
                    my $request = h2_request(1, $path, $method);
                    return 11 unless $s->syswrite($request) == length($request);
                    return 12 unless (read_h2_response($s, 1, $status) // 'missing') eq $expected_body;
                } else {
                    my $request = "$method $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                    return 13 unless $s->syswrite($request) == length($request);
                    return 14 unless (read_http_response($s, length($expected_body), $status) // 'missing')
                        eq $expected_body;
                }
                $s->close;
            }
            return 0;
        };

        wait_for_close($f);
        is_deeply \@completed, ['/first', '/second', '/third', '/head',
            '/status-204', '/status-205', '/status-304'], 'each guard fires once, including bodyless responses';
        is $f->active_conns, 0, 'guards release all connections and streams';

        @completed = ();
        run_client 'guards on a reused connection', sub {
            my $s = connect_client($transport, $port) or return 20;
            for my $id (1, 3) {
                my $path = $id == 1 ? '/keep-first' : '/keep-second';
                my $request = $transport eq 'h2' ? h2_request($id, $path)
                    : "GET $path HTTP/1.1\r\nHost: x\r\n"
                        . ($id == 3 ? "Connection: close\r\n" : '') . "\r\n";
                return 21 unless $s->syswrite($request) == length($request);
                my $body = $transport eq 'h2' ? read_h2_response($s, $id) : read_http_response($s, 2);
                return 22 unless ($body // '') eq 'OK';
            }
            $s->close;
            return 0;
        };
        wait_for_close($f);
        is_deeply \@replacement, $transport eq 'h2' ? [1, 1] : [0, 1],
            'H1 guards wait for replacement; H2 guards fire at stream completion';
        is_deeply \@completed, ['/keep-first', '/keep-second'], 'reused connections fire each guard once';
        is $f->active_conns, 0, 'reused connections and streams are released';

        @completed = ();
        run_client 'cancel guarded response', sub {
            my $s = connect_client($transport, $port) or return 30;
            if ($transport eq 'h2') {
                my $request = h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 0)) . h2_request(1, '/abort');
                return 31 unless $s->syswrite($request) == length($request);
                my $headers = h2_read_until($s, H2_HEADERS, 1, 3 * TMULT);
                return 32 unless $headers && hpack_decode_status($headers->{payload}) == 200;
                my $before = h2_request(3, '/probe')
                    . h2_frame(H2_WINDOW_UPDATE, 0, 3, pack('N', 65535));
                return 33 unless $s->syswrite($before) == length($before);
                return 34 unless (read_h2_response($s, 3) // 'missing') eq '';
                $s->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 8)));
                # cleanup runs at the loop boundary, so a probe sent beside the
                # reset may precede it; the next probe must see the fired guard
                my $fired = 0;
                for my $id (5, 7) {
                    my $probe_request = h2_request($id, '/probe')
                        . h2_frame(H2_WINDOW_UPDATE, 0, $id, pack('N', 65535));
                    return 35 unless $s->syswrite($probe_request) == length($probe_request);
                    if ((read_h2_response($s, $id) // '') eq '/abort') { $fired = 1; last }
                }
                return 36 unless $fired;
                $s->close;
            } else {
                my $request = "GET /abort HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                return 37 unless $s->syswrite($request) == length($request);
                return 38 unless defined read_http_response($s, 0);
                setsockopt($s, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) or return 39;
                $transport =~ /^plain/ ? $s->close : $s->close(SSL_no_shutdown => 1);
            }
            return 0;
        };
        wait_for_close($f);
        is_deeply \@completed, ['/abort'], 'cancellation fires the guard once';
        is scalar @cancelled_bytes, 1, 'guard records the cancelled download';
        cmp_ok $cancelled_bytes[0] // $download_size, '<', $download_size,
            'cleanup happens before the response finishes';
        is $f->active_conns, 0, 'cancelled connections and streams are released';
        is scalar keys %writers, 0, 'guard releases the app-held streaming writer';
        my $drained = 0;
        $f->graceful_shutdown(sub { $drained++ });
        is $drained, 1, 'response guards do not prevent graceful shutdown';
        done_testing;
    };
}
done_testing;
