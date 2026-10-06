#!perl
# A normal input poll callback drains one completed request body. It must not
# take over the socket, expose a pipelined request, or change EOF to EAGAIN.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use IO::Socket::INET;
use POSIX ();
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
        my $pid = fork;
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            $SIG{QUIT} = 'DEFAULT';
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->set_keepalive(1);
            $f->linger_timeout(0);
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
                        h2 => $transport eq 'h2' ? 1 : 0)
                if $transport ne 'plain';
            $f->psgi_request_handler(sub {
                my $env = shift;
                my $mode = substr $env->{PATH_INFO}, 1;
                return [200, [], ['after-ok']] if $mode eq 'after';
                my $input = $env->{'psgi.input'};
                my $body = '';
                if ($mode =~ /^poll-/) {
                    $input->poll_cb(sub {
                        my $reader = shift;
                        return if $mode eq 'poll-unset';
                        if ($mode eq 'poll-read') {
                            $reader->read($body, 2);
                        } else {
                            local $/ = \2;
                            my $part = $reader->getline;
                            $body .= $part if defined $part;
                        }
                    });
                    if ($mode eq 'poll-unset') {
                        $input->poll_cb(undef);
                        local $/;
                        $body = $input->getline // '';
                    }
                } elsif ($mode eq 'read') {
                    $input->read($body, 65536);
                } else {
                    $input->seek(65536, 1) if $mode eq 'seek';
                    local $/;
                    $body = $input->getline // '';
                }
                my $eof = $input->read(my $tail, 65536);
                $input->poll_cb(undef) if $mode =~ /^poll-/;
                my $out = 'body=' . unpack('H*', $body)
                        . ' eof=' . (defined $eof ? $eof : 'EAGAIN');
                return [200, [], [$out]];
            });
            EV::now_update();
            my $life = EV::timer(120 * TMULT, 0, sub { POSIX::_exit(0) });
            EV::run;
            POSIX::_exit(0);
        }
        my $cleanup = guard { reap_server($pid) };
        close $listen;

        if ($transport eq 'h2') {
            for my $body ('', 'DATA') {
                for my $mode (qw(read getline seek poll-read poll-getline poll-unset)) {
                    subtest "$mode / " . (length($body) ? 'body' : 'empty') => sub {
                        my $s = h2_connect($port) or die 'H2 connect failed';
                        my $request = h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1,
                            hpack_encode_headers([':method', 'POST'], [':scheme', 'https'],
                                [':authority', 'x'], [':path', "/$mode"], ['content-length', length($body)]))
                            . h2_frame(H2_DATA, FLAG_END_STREAM, 1, $body);
                        is $s->syswrite($request), length($request), 'request sent';
                        my ($status, $content, $ended) = (undef, '', 0);
                        my $deadline = time + 3 * TMULT;
                        while (time < $deadline) {
                            my $frame = h2_read_frame($s, 0.1) or next;
                            next unless $frame->{stream_id} == 1;
                            $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
                            $content .= $frame->{payload} if $frame->{type} == H2_DATA;
                            if (($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
                                && ($frame->{flags} & FLAG_END_STREAM)) { $ended = 1; last }
                        }
                        is $status, 200, 'normal request succeeds';
                        ok $ended, 'response completes';
                        my $expected = $mode eq 'seek' ? '' : unpack('H*', $body);
                        is $content, "body=$expected eof=0", 'reader preserves its completed body and EOF';
                        $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3,
                            hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                                [':authority', 'x'], [':path', '/after'])));
                        my $next = h2_read_until($s, H2_HEADERS, 3, 3 * TMULT);
                        is $next ? hpack_decode_status($next->{payload}) : 'no response', 200,
                            'connection serves another stream';
                        my ($after, $after_ended) = ('', $next && ($next->{flags} & FLAG_END_STREAM));
                        $deadline = time + 3 * TMULT;
                        while (!$after_ended && time < $deadline) {
                            my $frame = h2_read_frame($s, 0.1) or next;
                            next unless $frame->{stream_id} == 3;
                            $after .= $frame->{payload} if $frame->{type} == H2_DATA;
                            $after_ended = $frame->{flags} & FLAG_END_STREAM
                                if $frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA;
                        }
                        ok $after_ended, 'the next stream completes';
                        is $after, 'after-ok', 'the next response body is intact';
                        $s->close;
                        done_testing;
                    };
                }
            }
            undef $cleanup;
            done_testing;
            return;
        }

        my @bodies = (
            ['implicit empty GET', 'GET', '', '', ''],
            ['zero Content-Length', 'POST', "Content-Length: 0\r\n", '', ''],
            ['empty chunked', 'POST', "Transfer-Encoding: chunked\r\n", "0\r\n\r\n", ''],
            ['Content-Length body', 'POST', "Content-Length: 4\r\n", 'DATA', 'DATA'],
            ['chunked body', 'POST', "Transfer-Encoding: chunked\r\n", "4\r\nDATA\r\n0\r\n\r\n", 'DATA'],
        );
        for my $case (@bodies) {
            my ($name, $method, $headers, $wire_body, $body) = @$case;
            for my $mode (qw(read getline seek poll-read poll-getline poll-unset)) {
                for my $pipeline (0, 1) {
                    subtest "$name / $mode / " . ($pipeline ? 'pipeline' : 'single') => sub {
                        my $s = $transport eq 'tls'
                            ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
                                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(), Timeout => 5 * TMULT)
                            : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 5 * TMULT);
                        die "connect: $!" unless $s;
                        my $request = "$method /$mode HTTP/1.1\r\nHost: x\r\n$headers"
                            . ($pipeline ? '' : "Connection: close\r\n") . "\r\n$wire_body";
                        $request .= "GET /after HTTP/1.1\r\nHost: x\r\n"
                                  . "Authorization: Bearer SECRET\r\nConnection: close\r\n\r\n"
                            if $pipeline;
                        my ($response, $error) = ('', '');
                        eval {
                            local $SIG{ALRM} = sub { die "request timeout\n" };
                            alarm 5 * TMULT;
                            my $offset = 0;
                            while ($offset < length $request) {
                                my $n = syswrite($s, $request, length($request) - $offset, $offset);
                                die "write: $!" unless $n;
                                $offset += $n;
                            }
                            while (sysread($s, my $part, 65536)) { $response .= $part }
                            alarm 0;
                            1;
                        } or do { $error = $@; alarm 0 };
                        close $s;
                        is $error, '', 'response completes promptly';
                        my $expected = $mode eq 'seek' ? '' : unpack('H*', $body);
                        like $response, qr/body=\Q$expected\E eof=0(?:HTTP|\z)/,
                            'reader sees only its body and EOF';
                        my $responses = () = $response =~ /HTTP\/1\.1 200\b/g;
                        is $responses, $pipeline ? 2 : 1, 'all requests receive their own response';
                        like $response, qr/after-ok\z/, 'pipelined request stays intact' if $pipeline;
                        done_testing;
                    };
                }
            }
        }
        undef $cleanup;
        done_testing;
    };
}
done_testing;
