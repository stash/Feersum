#!perl
# write_timeout reaps an H2 stream held behind a zero flow-control window and
# a parent connection whose ciphertext buffer backs up, and a PING flood against
# a non-reading peer is bounded by FEER_H2_MAX_WBUF.  The deadline tracks
# progress, not elapsed time: a body too large for one write_timeout completes.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use AnyEvent;
use H2Utils;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_RCVBUF);
use Time::HiRes ();
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 5;

my $WT    = 2 * TIMEOUT_MULT;
my $SMALL = 1000;
# Small on purpose.  What stretches the transfer past write_timeout is the
# pacing below, not the byte count, so there is nothing to gain from a big
# body - and plenty to lose: at 4MB this test moved 1MB in 240s on a netbsd
# runner and failed as INCOMPLETE, measuring that VM's H2 throughput through a
# hand-rolled Perl client rather than anything about the deadline.
my $BIG   = 256 * 1024;

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout(120 * TIMEOUT_MULT);
    $f->header_timeout(120 * TIMEOUT_MULT);
    $f->write_timeout($WT);
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 1) };
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $big = ($env->{PATH_INFO} // '') eq '/big';
        my $len = $big ? $BIG : $SMALL;
        return [200, ['Content-Type' => 'application/octet-stream',
                      'Content-Length' => $len], ['Z' x $len]];
    });
    my $life_timer = EV::timer(180 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

# Connect and do the H2 preface with an optional SETTINGS payload.
sub h2_open {
    my ($settings_payload, %o) = @_;
    my $raw = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                    Timeout => 10 * TIMEOUT_MULT) or return undef;
    setsockopt($raw, SOL_SOCKET, SO_RCVBUF, pack('i', 4096)) if $o{small_rcvbuf};
    my $s = IO::Socket::SSL->start_SSL($raw,
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2']) or return undef;
    $s->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
               . h2_frame(H2_SETTINGS, 0, 0, $settings_payload // ''));
    $s->blocking(0);
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($s, 1) or last;
        if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
            $s->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
            last;
        }
    }
    return $s;
}
sub h2_get {
    my ($s, $path) = @_;
    my $hdrs = hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                                    [':authority', "127.0.0.1:$port"],
                                    [':path', $path]);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdrs));
}

# --- 1: a stream stalled behind a zero window is reaped
{
    # INITIAL_WINDOW_SIZE (0x4) = 0: nothing may be sent at all.
    my $s = h2_open(pack('nN', 0x4, 0));
    ok $s, 'connected with a zero initial window';
    my ($reaped, $data) = (0, 0);
  SKIP: {
        skip 'no connection', 1 unless $s;
        h2_get($s, '/small');
        my $t0 = Time::HiRes::time();
        my $next_ping = $t0 + 0.4;
        # PING keeps read_timeout away, so only a WRITE deadline can reap this.
        while (Time::HiRes::time() - $t0 < $WT * 3) {
            if (Time::HiRes::time() >= $next_ping) {
                last unless $s->syswrite(h2_frame(H2_PING, 0, 0, 'feersum1'));
                $next_ping = Time::HiRes::time() + 0.4;
            }
            my $f = h2_read_frame($s, 0.2) or next;
            $data += length $f->{payload} if $f->{type} == H2_DATA;
            if ($f->{type} == H2_RST_STREAM || $f->{type} == H2_GOAWAY) {
                $reaped = 1;
                last;
            }
        }
        close $s;
        ok $reaped,
            'a stream stalled behind the peer\'s flow-control window is reaped '
          . "by write_timeout=$WT (received $data body bytes)";
    }
}

# --- 2: a body too large to deliver inside write_timeout must NOT be reset
{
    my $s = h2_open();
    my ($data, $rst, $done) = (0, 0, 0);
  SKIP: {
        skip 'no connection', 1 unless $s;
        h2_get($s, '/big');
        my $t0 = Time::HiRes::time();
        # Pacing is driven by progress, not the wall clock, and each pause is a
        # quarter of write_timeout: 16 of them make the transfer outlast the
        # deadline several times over while no single gap comes near it, so the
        # test measures the server on a slow machine, not the client.
        my $pause = $WT / 4;
        my $chunk = $BIG / 16;
        my $next_pause = $chunk;
        # Prime the window, then top it up after every read.
        $s->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $chunk)));
        $s->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', $chunk)));
        while (Time::HiRes::time() - $t0 < 120 * TIMEOUT_MULT && !$rst && !$done) {
            my $f = h2_read_frame($s, 0.2);
            if ($f) {
                if ($f->{type} == H2_DATA) {
                    $data += length $f->{payload};
                    $done = 1 if $f->{flags} & FLAG_END_STREAM;
                    my $n = length $f->{payload};
                    if ($n) {
                        $s->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 0, pack('N', $n)));
                        $s->syswrite(h2_frame(H2_WINDOW_UPDATE, 0, 1, pack('N', $n)));
                    }
                }
                elsif ($f->{type} == H2_RST_STREAM || $f->{type} == H2_GOAWAY) {
                    $rst = 1;
                }
            }
            # Stretch the transfer past write_timeout in steps far shorter
            # than it, so the deadline must be refreshed by progress to survive.
            # One pause per crossed boundary, never several back to back:
            # consecutive sleeps could add up to a gap the deadline would
            # rightly fire on.
            if ($data >= $next_pause) {
                $next_pause += $chunk;
                Time::HiRes::sleep($pause);
            }
        }
        my $el = Time::HiRes::time() - $t0;
        close $s;
        # $el > $WT is part of the assertion, not decoration: if the transfer
        # finishes inside the deadline the case proves nothing, and an earlier
        # version of this test quietly did exactly that - it passed with the
        # progress-refresh removed.
        ok(($done && $data == $BIG && $el > $WT),
            sprintf('a transfer that keeps making progress is not reset, even '
                  . 'though it takes %.1fs against write_timeout=%d (%d of %d '
                  . 'bytes%s)', $el, $WT, $data, $BIG,
                    $rst ? ', WAS RESET'
                         : (!$done ? ', INCOMPLETE'
                                   : ($el <= $WT ? ', TOO FAST TO PROVE ANYTHING'
                                                 : ''))));
    }
}

# --- 3: a PING flood against a peer that never reads is bounded and closed
{
    # Both limits bound the FAILURE path only: a healthy server closes the
    # connection first and the loop stops right there.  Asserting a byte
    # ceiling rather than just "died" is the point - unbounded growth reached
    # 289MB of accepted flood (2.1GB RSS) before write_timeout caught it, and
    # nothing caught it at all with write_timeout left at its default of 0.
    my $FLOOD_CAP = 64 * 1024 * 1024;
    my $s = h2_open(undef, small_rcvbuf => 1);
    my ($dead, $sent) = (0, 0);
  SKIP: {
        skip 'no connection', 1 unless $s;
        $s->blocking(1);
        local $SIG{PIPE} = 'IGNORE';
        my $t0 = Time::HiRes::time();
        # PING ACKs go straight to the connection's ciphertext buffer with no
        # stream involved, so this exercises the parent, not the per-stream
        # deadline.  Never read them.
        while (Time::HiRes::time() - $t0 < $WT * 20 && $sent < $FLOOD_CAP) {
            my $n = $s->syswrite(h2_frame(H2_PING, 0, 0, 'feersum1') x 64);
            if (!defined $n || $n == 0) { $dead = 1; last }
            $sent += $n;
        }
        close $s;
        ok(($dead && $sent < $FLOOD_CAP),
            sprintf('a PING flood against a peer that never reads is bounded '
                  . 'and closed (%.1fMB accepted%s)', $sent / 1048576,
                    $dead ? q{} : ', STILL OPEN'));
    }
}

reap_server($server);
