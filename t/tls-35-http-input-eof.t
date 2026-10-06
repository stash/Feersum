#!perl
# Closing the TLS input side must preserve complete HTTP requests and their
# replies, without waiting for more requests on a stream that already ended.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use IO::Select;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);
use Socket qw(SHUT_WR);
use Errno qw(EAGAIN EWOULDBLOCK);
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS unavailable' unless $probe->has_tls
    && eval { require IO::Socket::SSL; require Net::SSLeay; 1 } && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my ($stall_listen, $stall_port) = get_listen_socket();
die "stall listen: $!" unless $stall_listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_keepalive(1);
    $f->read_timeout(8 * TMULT);
    $f->header_timeout(8 * TMULT);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
        h2 => $probe->has_h2 ? 1 : 0);
    my (%timers, $next_timer);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $body = $env->{PATH_INFO};
        if ($body eq '/polled') {
            return sub {
                my $respond = shift;
                my $writer = $respond->([200, ['Content-Length', length($body)]]);
                $writer->poll_cb(sub { return });
                my $id = ++$next_timer;
                $timers{$id} = EV::timer(0.2 * TMULT, 0, sub {
                    delete $timers{$id};
                    $writer->write($body);
                    $writer->close;
                });
            };
        }
        return sub {
            my $respond = shift;
            my $id = ++$next_timer;
            $timers{$id} = EV::timer(0.2 * TMULT, 0, sub {
                delete $timers{$id};
                $respond->([200, [], [$body]]);
            });
        };
    });
    my $stalled = Feersum->new_instance;
    $stalled->use_socket($stall_listen);
    $stalled->read_timeout(0.4 * TMULT);
    $stalled->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key',
        h2 => $probe->has_h2 ? 1 : 0);
    $stalled->request_handler(sub {
        my $conn = shift;
        my $io = $conn->io;
        syswrite($io, 'finish');
        close $io;
    });
    my $stats = EV::timer(0.02, 0.02, sub {
        open my $out, '>', "$dir/active" or die $!;
        print {$out} $f->active_conns + $stalled->active_conns;
        close $out;
    });
    my $life = EV::timer(40 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;
close $stall_listen;

# pair the request record with close_notify; record 1 is the TLS 1.3 Finished
sub coalescing_proxy {
    my $lsn = IO::Socket::INET->new(LocalAddr => '127.0.0.1', Proto => 'tcp',
        Listen => 5) or die "relay listen: $!";
    my $relay_port = $lsn->sockport;
    my $relay_pid = fork;
    die "relay fork: $!" unless defined $relay_pid;
    if (!$relay_pid) {
        $SIG{QUIT} = 'DEFAULT';
        my $client = $lsn->accept or POSIX::_exit(1);
        my $server = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port)
            or POSIX::_exit(1);
        my $sel = IO::Select->new($client, $server);
        my ($buf, $held, $seen) = ('', '', 0);
        while (my @ready = $sel->can_read(10 * TMULT)) {
            for my $socket (@ready) {
                my $n = sysread($socket, my $part, 65536);
                unless ($n) {
                    if ($socket == $client) {
                        CORE::shutdown($server, SHUT_WR);
                        $sel->remove($client);
                        next;
                    }
                    POSIX::_exit(0);
                }
                if ($socket == $server) { syswrite($client, $part); next }
                $buf .= $part;
                while (length($buf) >= 5) {
                    my ($type, undef, $length) = unpack('Cnn', $buf);
                    last if length($buf) < 5 + $length;
                    my $record = substr($buf, 0, 5 + $length, '');
                    $seen++ if $type == 23;
                    if ($type == 23 && $seen == 2) { $held = $record; next }
                    if ($type == 23 && $seen == 3) {
                        $record = $held . $record;
                        $held = '';
                    }
                    syswrite($server, $record);
                }
            }
        }
        POSIX::_exit(0);
    }
    close $lsn;
    return ($relay_port, guard { reap_server($relay_pid) });
}

sub active_count {
    my $active = -1;
    my $deadline = time + TMULT;
    while (time < $deadline) {
        if (open my $in, '<', "$dir/active") { $active = <$in> // -1; close $in }
        last if $active == 0;
        sleep 0.02;
    }
    return $active;
}

my @h1_cases = (
    ['one request', "GET /coalesced HTTP/1.1\r\nHost: x\r\n\r\n", '/coalesced', 1],
    ['pipelined requests', "POST /first HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
        . "GET /second HTTP/1.1\r\nHost: x\r\n\r\n", '/second', 2],
    ['chunked pipeline', "POST /first HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
        . "GET /second HTTP/1.1\r\nHost: x\r\n\r\n", '/second', 2],
    ['incomplete successor', "GET /first HTTP/1.1\r\nHost: x\r\n\r\n"
        . "POST /incomplete HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na", '/first', 1],
    ['incomplete request', "POST /incomplete HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\na", '', 0],
    ['parked streaming response', "GET /polled HTTP/1.1\r\nHost: x\r\n\r\n", '/polled', 1, 1],
);
for my $case (@h1_cases) {
    subtest "HTTP/1 $case->[0] coalesced with close_notify" => sub {
        my ($relay_port, $relay_cleanup) = coalescing_proxy();
        my $s = IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $relay_port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            SSL_alpn_protocols => ['http/1.1'], Timeout => 5 * TMULT);
        die 'TLS connect failed' unless $s;
        syswrite($s, $case->[1]);
        my $rv = Net::SSLeay::shutdown($s->_get_ssl_object);
        die "SSL shutdown: $rv" if $rv < 0;
        CORE::shutdown($s, SHUT_WR) or die "shutdown: $!" if $case->[4];
        my ($response, $eof) = ('', 0);
        eval {
            local $SIG{ALRM} = sub { die "response timeout\n" };
            alarm 2 * TMULT;
            while (1) {
                my $n = sysread($s, my $part, 65536);
                last unless defined $n;
                if ($n == 0) { $eof = 1; last }
                $response .= $part;
            }
            alarm 0;
            1;
        } or do { alarm 0; diag $@ };
        my $responses = () = $response =~ m{HTTP/1\.1 200}g;
        is $responses, $case->[3], 'only complete requests get replies';
        like $response, qr{\r\n\r\n\Q$case->[2]\E\z}, 'last complete request gets its delayed body'
            if $case->[3];
        ok $eof, 'server closes after replying instead of waiting for another request';
        is active_count(), 0, 'input closure releases the connection';
        close $s;
        undef $relay_cleanup;
        done_testing;
    };
}

if ($probe->has_h2) {
    for my $kind ('close_notify', 'FIN') {
        subtest "HTTP/2 $kind preserves a pending reply" => sub {
            my ($s) = h2_connect($port, timeout => 5 * TMULT);
            die 'H2 connect failed' unless $s;
            $s->blocking(1);
            my $headers = hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                [':authority', 'x'], [':path', '/delayed']);
            syswrite($s, h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $headers));
            if ($kind eq 'FIN') { CORE::shutdown($s, SHUT_WR) or die "shutdown: $!" }
            else {
                my $rv = Net::SSLeay::shutdown($s->_get_ssl_object);
                die "SSL shutdown: $rv" if $rv < 0;
            }
            $s->blocking(0);
            my $head = h2_read_until($s, H2_HEADERS, 1, 2 * TMULT);
            is $head ? hpack_decode_status($head->{payload}) : undef, 200, 'pending request gets its status';
            my $data = h2_read_until($s, H2_DATA, 1, 2 * TMULT);
            is $data ? $data->{payload} : undef, '/delayed', 'pending response body reaches the peer';
            is active_count(), 0, 'reply completion releases the half-closed connection';
            close $s;
            done_testing;
        };
    }
    subtest 'HTTP/2 incomplete request does not drop a complete sibling' => sub {
        my ($s) = h2_connect($port, timeout => 5 * TMULT);
        die 'H2 connect failed' unless $s;
        $s->blocking(1);
        my $incomplete = hpack_encode_headers([':method', 'POST'], [':scheme', 'https'],
            [':authority', 'x'], [':path', '/incomplete'], ['content-length', '3']);
        my $complete = hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', 'x'], [':path', '/sibling']);
        syswrite($s, h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $incomplete)
            . h2_frame(H2_DATA, 0, 1, 'a')
            . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3, $complete));
        my $rv = Net::SSLeay::shutdown($s->_get_ssl_object);
        die "SSL shutdown: $rv" if $rv < 0;
        $s->blocking(0);
        my ($reset, $status, $body) = (0, undef, '');
        my $deadline = time + 2 * TMULT;
        while (time < $deadline && (!defined $status || $body ne '/sibling' || !$reset)) {
            my $frame = h2_read_frame($s, 0.1) or next;
            $reset = 1 if $frame->{type} == H2_RST_STREAM && $frame->{stream_id} == 1;
            next unless $frame->{stream_id} == 3;
            $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
            $body .= $frame->{payload} if $frame->{type} == H2_DATA;
        }
        ok $reset, 'incomplete request is reset';
        is $status, 200, 'complete sibling gets its status';
        is $body, '/sibling', 'complete sibling gets its full delayed body';
        is active_count(), 0, 'both streams release the connection';
        close $s;
        done_testing;
    };
    subtest 'HTTP/2 EOF bounds a tunnel behind a zero send window' => sub {
        my ($s) = h2_connect($stall_port, timeout => 5 * TMULT);
        die 'H2 connect failed' unless $s;
        $s->blocking(1);
        my $headers = hpack_encode_headers([':method', 'CONNECT'], [':protocol', 'websocket'],
            [':scheme', 'https'], [':authority', 'x'], [':path', '/stalled']);
        syswrite($s, h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 0))
            . h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $headers));
        $s->blocking(0);
        my $head = h2_read_until($s, H2_HEADERS, 1, 2 * TMULT);
        is $head ? hpack_decode_status($head->{payload}) : undef, 200, 'tunnel accepted';
        $s->blocking(1);
        my $rv = Net::SSLeay::shutdown($s->_get_ssl_object);
        die "SSL shutdown: $rv" if $rv < 0;
        $s->blocking(0);
        my ($closed, $deadline) = (0, time + 2 * TMULT);
        while (time < $deadline) {
            my $n = sysread($s, my $part, 65536);
            if ((defined $n && $n == 0)
                || (!defined $n && $! != EAGAIN && $! != EWOULDBLOCK)) {
                $closed = 1;
                last;
            }
            sleep 0.02;
        }
        ok $closed, 'impossible-to-drain tunnel reply reaches the stalled-connection bound';
        is active_count(), 0, 'stalled tunnel releases its stream and admission capacity';
        close $s;
        done_testing;
    };
}
undef $cleanup;
done_testing;
