#!perl
# END_STREAM must reach the app as EOF after every queued DATA byte has
# drained through the socketpair, even when the app starts reading slowly.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time);
use POSIX ();
use Socket qw(SHUT_WR);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();
eval { require Net::SSLeay; 1 } or plan skip_all => 'Net::SSLeay unavailable';
my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    my %keep;
    $f->request_handler(sub {
        my $conn = shift;
        my $path = $conn->path;
        my $state = { bytes => 0, sha => Digest::SHA->new(256) };
        $keep{$path} = $state;
        my $setup = sub {
            my $io = $state->{io} = $conn->io;
            # small flat delay to queue client bytes before the app reads;
            # backpressure is the 64K window vs 512K payload, not this delay
            $state->{delay} = EV::timer(0.5, 0, sub {
                delete $state->{delay};
                $state->{read} = EV::io($io, EV::READ, sub {
                    my $n = sysread($io, my $data, 16384);
                    return unless defined $n;
                    if ($n > 0) {
                        $state->{bytes} += $n;
                        $state->{sha}->add($data);
                        return;
                    }
                    my $result = "$state->{bytes} " . $state->{sha}->hexdigest;
                    open my $out, '>', "$dir$path" or die $!;
                    print {$out} "$result\n";
                    close $out;
                    syswrite($io, "received:$result\n");
                    delete $state->{read};
                    close $io;
                    delete $keep{$path};
                });
            });
        };
        if ($path =~ /before-setup/) {
            $state->{setup} = EV::timer(0.5, 0, sub {
                delete $state->{setup};
                $setup->();
                undef $setup;
            });
        } else {
            $setup->();
        }
    });
    my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

my $large_payload = join('', map { pack('N', $_) } 0 .. 131071);  # 512 KiB, larger than the socketpair
for my $case ('headers-empty', 'data', 'before-setup', 'trailers', 'close-notify', 'fin', 'notify-before-setup') {
    subtest $case => sub {
        my $transport_eof = $case eq 'fin' || $case =~ /notify/;
        my $payload = $case eq 'headers-empty' ? '' : $large_payload;
        my ($s) = h2_connect($port, timeout => 5 * TMULT);
        die 'H2 connect failed' unless $s;
        my $headers = hpack_encode_headers([':method', 'CONNECT'], [':protocol', 'websocket'],
            [':scheme', 'https'], [':authority', 'x'], [':path', "/$case"]);
        my $header_flags = FLAG_END_HEADERS;
        $header_flags |= FLAG_END_STREAM if $case eq 'headers-empty';
        $s->syswrite(h2_frame(H2_HEADERS, $header_flags, 1, $headers));
        my $accepted;
        unless ($case =~ /before-setup/) {
            my $frame = h2_read_until($s, H2_HEADERS, 1, 5 * TMULT);
            $accepted = hpack_decode_status($frame->{payload}) if $frame;
        }
        my ($offset, $conn_window, $stream_window) = (0, 65535, 65535);
        my ($response, $reset, $ended) = ('', 0, 0);
        my $receive = sub {
            my $frame = shift;
            if ($frame->{type} == H2_WINDOW_UPDATE) {
                my $inc = unpack('N', $frame->{payload}) & 0x7fffffff;
                $conn_window += $inc if $frame->{stream_id} == 0;
                $stream_window += $inc if $frame->{stream_id} == 1;
            }
            if ($frame->{stream_id} == 1) {
                $accepted = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
                $response .= $frame->{payload} if $frame->{type} == H2_DATA;
                $ended = 1 if ($frame->{type} == H2_DATA || $frame->{type} == H2_HEADERS)
                    && ($frame->{flags} & FLAG_END_STREAM);
            }
            $reset = 1 if $frame->{type} == H2_RST_STREAM
                || ($frame->{type} == H2_GOAWAY && (!$transport_eof
                    || unpack('N', substr($frame->{payload}, 4, 4)) != 0));
        };
        my $deadline = time + 12 * TMULT;
        while ($offset < length($payload) && time < $deadline && !$reset) {
            my $n = length($payload) - $offset;
            $n = 16000 if $n > 16000;
            if ($conn_window >= $n && $stream_window >= $n) {
                my $end = $case ne 'trailers' && !$transport_eof
                    && $offset + $n == length($payload) ? FLAG_END_STREAM : 0;
                my $frame = h2_frame(H2_DATA, $end, 1, substr($payload, $offset, $n));
                $s->blocking(1);
                my $sent = 0;
                while ($sent < length $frame) {
                    my $written = syswrite($s, $frame, length($frame) - $sent, $sent);
                    die "write: $!" unless $written;
                    $sent += $written;
                }
                $s->blocking(0);
                $offset += $n;
                $conn_window -= $n;
                $stream_window -= $n;
            }
            while (my $frame = h2_read_frame($s, 0.005)) { $receive->($frame) }
        }
        is $offset, length($payload), 'client sends the complete payload within the flow-control windows';
        if ($case eq 'trailers') {
            $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
                hpack_encode_headers(['x-finished', 'yes'])));
        }
        if ($transport_eof) {
            $s->blocking(1);
            if ($case eq 'fin') { CORE::shutdown($s, SHUT_WR) or die "shutdown: $!" }
            else {
                my $rv = Net::SSLeay::shutdown($s->_get_ssl_object);
                die "SSL shutdown: $rv" if $rv < 0;
            }
            $s->blocking(0);
        }

        my $result_file = "$dir/$case";
        $deadline = time + 8 * TMULT;
        while (time < $deadline && (!-e $result_file || (!$ended && !$reset))) {
            my $frame = h2_read_frame($s, 0.1);
            $receive->($frame) if $frame;
        }
        my $result = '';
        if (open my $in, '<', $result_file) { $result = <$in> // ''; close $in; chomp $result }
        is $accepted, 200, 'tunnel accepted';
        is $result, length($payload) . ' ' . sha256_hex($payload), 'app receives every byte in order before EOF';
        is $response, "received:$result\n", 'app can finish its response after the client half-close';
        ok $ended && !$reset, 'half-closing a backpressured tunnel ends without a reset';
        close $s;
        done_testing;
    };
}
undef $cleanup;
done_testing;
