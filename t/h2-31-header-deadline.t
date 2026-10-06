#!perl
# HTTP/2 header blocks must obey the same non-resetting header deadline as
# HTTP/1, even when their frame payload continues to arrive on the idle clock.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use Time::HiRes qw(time sleep);
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->header_timeout(0.5 * TMULT);
    $f->read_timeout(2 * TMULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        $f->header_timeout(0) if $env->{PATH_INFO} eq '/disable';
        [200, [], ['ok']];
    });
    my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

sub headers {
    my ($path) = @_;
    hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
        [':authority', 'x'], [':path', $path // '/']);
}

sub expect_ok {
    my ($s, $label, $sid) = @_;
    $sid //= 1;
    my $frame = h2_read_until($s, H2_HEADERS, $sid, 5 * TMULT);
    is $frame ? hpack_decode_status($frame->{payload}) : undef, 200, $label;
    my $data = h2_read_until($s, H2_DATA, $sid, 5 * TMULT);
    is $data ? $data->{payload} : undef, 'ok', 'complete response body';
}

# invalid-header and final-frame never complete the block, so the deadline (not
# the field content) fires the GOAWAY; they guard against an early RST shortcut.
for my $case ('preface', 'request', 'trailers', 'invalid-header', 'final-frame') {
    subtest $case => sub {
        my $s;
        if ($case eq 'preface') {
            $s = IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['h2'], Timeout => 5 * TMULT);
            $s->blocking(0) if $s;
        } else {
            ($s) = h2_connect($port, timeout => 5 * TMULT);
        }
        die 'H2 connect failed' unless $s;
        if ($case eq 'trailers') {
            $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, headers()));
        }
        # drip the header block so read_timeout keeps being refreshed
        my ($tail, $step);
        if ($case eq 'preface') {
            my $preface = h2_client_preface();
            $s->syswrite(substr($preface, 0, 1));
            $tail = substr($preface, 1);
            $step = 1;
        } else {
            my $block = $case eq 'trailers' ? hpack_encode_headers(['x-first', 'one']) : headers();
            $block .= hpack_encode_headers(['connection', 'close'])
                if $case eq 'invalid-header' || $case eq 'final-frame';
            $tail = hpack_encode_headers(['x-slow', 'S' x 200]);
            $step = 10;
            if ($case eq 'final-frame') {
                my $frame = h2_frame(H2_HEADERS, FLAG_END_STREAM | FLAG_END_HEADERS, 1, $block . $tail);
                $s->syswrite(substr($frame, 0, 9 + length($block)));
            } else {
                $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_STREAM, 1, $block));
                my $continuation = h2_frame(0x9, FLAG_END_HEADERS, 1, $tail);
                $s->syswrite(substr($continuation, 0, 9));
            }
        }
        my ($refused, $reply) = (0, '');
        local $SIG{PIPE} = 'IGNORE';
        for my $i (0 .. 11) {
            sleep 0.1 * TMULT;
            $s->syswrite(substr($tail, $i * $step, $step));
            while (my $frame = h2_read_frame($s, 0.01 * TMULT)) {
                $refused = 1 if $frame->{type} == H2_GOAWAY;
                $reply .= $frame->{payload} if $frame->{type} == H2_DATA;
            }
            last if $refused;
        }
        ok $refused, 'slow header block is refused despite continuing input';
        is $reply, '', 'incomplete headers never dispatch an application response';
        close $s;
        done_testing;
    };
}

subtest 'timely continuation after idle' => sub {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 reconnect failed' unless $s;
    sleep 0.8 * TMULT; # an idle negotiated connection has no header block pending
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_STREAM, 1, headers()));
    sleep 0.1 * TMULT;
    $s->syswrite(h2_frame(0x9, FLAG_END_HEADERS, 1, hpack_encode_headers(['x-done', 'yes'])));
    expect_ok($s, 'a timely split block succeeds after an idle interval');
    close $s;
    done_testing;
};

subtest 'body uses read timeout' => sub {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 reconnect failed' unless $s;
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, headers()));
    sleep 0.8 * TMULT; # longer than header_timeout, shorter than read_timeout
    $s->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, 'body'));
    expect_ok($s, 'complete headers stop the hard deadline during body reception');
    close $s;
    done_testing;
};

subtest 'timely byte-fragmented frame' => sub {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 reconnect failed' unless $s;
    my $frame = h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, headers());
    for my $i (0 .. length($frame) - 1) {
        $s->syswrite(substr($frame, $i, 1));
        # every few records: a short sleep rounds up to a 10-20ms tick on BSD
        sleep 0.001 * TMULT if $i % 6 == 5;
    }
    expect_ok($s, 'frame headers and HPACK may span many TLS records within the deadline');
    close $s;
    done_testing;
};

subtest 'completed rejected trailers stop the deadline' => sub {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 reconnect failed' unless $s;
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, headers()));
    my $trailers = hpack_encode_headers(map { ["x-trailer-$_", 'one'] } 1 .. 65);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $trailers));
    ok h2_read_until($s, H2_RST_STREAM, 1, 2 * TMULT), 'excess trailers reset their stream';
    sleep 0.8 * TMULT;
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3, headers()));
    expect_ok($s, 'a completed rejected block leaves healthy siblings usable', 3);
    close $s;
    done_testing;
};

subtest 'disabled deadline' => sub {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 reconnect failed' unless $s;
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, headers('/disable')));
    expect_ok($s, 'disable header_timeout through the normal server API');
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_STREAM, 3, headers()));
    sleep 0.8 * TMULT;
    $s->syswrite(h2_frame(0x9, FLAG_END_HEADERS, 3, hpack_encode_headers(['x-done', 'yes'])));
    my $frame = h2_read_until($s, H2_HEADERS, 3, 5 * TMULT);
    is $frame ? hpack_decode_status($frame->{payload}) : undef, 200,
        'a disabled deadline accepts a slow block on an existing connection';
    close $s;
    done_testing;
};
undef $cleanup;
done_testing;
