#!perl
# Completed-body callbacks may capture request metadata. They must be
# released without requiring the app to break cycles through psgi.input.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use IO::Socket::INET;
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
my @transports = ('plain');
push @transports, 'tls' if $probe->has_tls
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
push @transports, 'h2' if @transports > 1 && $probe->has_h2;

for my $transport (@transports) {
    subtest $transport => sub {
        my ($listen, $port) = get_listen_socket();
        die "listen: $!" unless $listen;
        my $f = Feersum->new_instance;
        $f->use_socket($listen);
        $f->set_keepalive(1);
        $f->linger_timeout(0);
        $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
                    h2 => $transport eq 'h2' ? 1 : 0) if $transport ne 'plain';
        $f->psgi_request_handler(sub {
            my $env = shift;
            return [200, [], ['after-ok']] if $env->{PATH_INFO} eq '/after';
            my $body = '';
            # captures only $env, a normal closure, not a retained Reader
            $env->{'psgi.input'}->poll_cb(sub {
                $_[0]->read($body, $env->{CONTENT_LENGTH});
            });
            return [200, [], ["got=[$body]"]];
        });

        run_client 'captured request metadata', sub {
            for my $body ('DATA', '', 'MORE') {
                if ($transport eq 'h2') {
                    my $s = h2_connect($port) or return 10;
                    my $request = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1,
                        hpack_encode_headers([':method', 'POST'], [':scheme', 'https'],
                            [':authority', 'x'], [':path', '/poll'], ['content-length', length($body)]))
                        . h2_frame(H2_DATA, FLAG_END_STREAM, 1, $body)
                        . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3,
                            hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                                [':authority', 'x'], [':path', '/after']));
                    return 11 unless $s->syswrite($request) == length($request);
                    my (%status, %content, %ended);
                    my $deadline = time + 5 * TMULT;
                    while (time < $deadline && keys(%ended) < 2) {
                        my $frame = h2_read_frame($s, 0.1) or next;
                        my $id = $frame->{stream_id};
                        next unless $id == 1 || $id == 3;
                        return 12 if $frame->{type} == H2_RST_STREAM;
                        $status{$id} = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
                        $content{$id} .= $frame->{payload} if $frame->{type} == H2_DATA;
                        $ended{$id} = 1 if ($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
                            && ($frame->{flags} & FLAG_END_STREAM);
                    }
                    return 13 unless keys(%ended) == 2 && ($status{1} // 0) == 200
                        && ($status{3} // 0) == 200 && ($content{1} // '') eq "got=[$body]"
                        && ($content{3} // '') eq 'after-ok';
                    $s->close;
                } else {
                    my $s = $transport eq 'tls'
                        ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
                            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(), Timeout => 5 * TMULT)
                        : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 5 * TMULT);
                    return 20 unless $s;
                    my $request = "POST /poll HTTP/1.1\r\nHost: x\r\nContent-Length: "
                        . length($body) . "\r\n\r\n$body"
                        . "GET /after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
                    return 21 unless $s->syswrite($request) == length($request);
                    my $reply = '';
                    eval {
                        local $SIG{ALRM} = sub { die "response timeout\n" };
                        alarm 5 * TMULT;
                        while ($s->sysread(my $part, 4096)) { $reply .= $part }
                        alarm 0;
                        1;
                    } or do { alarm 0; return 22 };
                    close $s;
                    my $responses = () = $reply =~ /HTTP\/1\.1 200\b/g;
                    return 23 unless $responses == 2 && $reply =~ /\Qgot=[$body]\E/
                        && $reply =~ /after-ok\z/;
                }
            }
            return 0;
        };

        # let the read watcher see the H2 client's close before counting
        if ($f->active_conns) {
            my $cv = AE::cv;
            my $deadline = time + 1 * TMULT;
            my $wait = AE::timer(0, 0.01, sub {
                $cv->send if !$f->active_conns || time >= $deadline;
            });
            $cv->recv;
        }
        is $f->active_conns, 0, 'completed callbacks release all connections and streams';
        $f->unlisten;
        done_testing;
    };
}
done_testing;
