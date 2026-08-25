#!perl
# max_h2_conn_body (off by default, set explicitly here) caps the sum of
# undispatched request-body bytes across a connection's streams, so a peer
# cannot hold max_h2_concurrent_streams x max_body_len by withholding END_STREAM.
use warnings; use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
use H2Utils;
use IO::Socket::INET;
use Time::HiRes ();
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();
plan tests => 4;

is $probe->max_h2_conn_body, 0, 'max_h2_conn_body defaults to off';

my $CAP   = 4 * 1024 * 1024;    # 4MB aggregate
my $FRAME = 16000;

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
    $f->max_h2_conn_body($CAP);
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 0, cert_file => 'eg/ssl-proxy/server.crt',
                       key_file => 'eg/ssl-proxy/server.key', h2 => 1) };
    $f->psgi_request_handler(sub {
        my $env = shift; my ($n, $b) = (0);
        $n += length $b while $env->{'psgi.input'}->read($b, 65536);
        [200, ['Content-Type' => 'text/plain',
               'Content-Length' => length "got"], ['got']] });
    my $life = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

sub open_h2 {
    my $raw = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                    Timeout => 10 * TIMEOUT_MULT) or die "connect: $!";
    my $s = IO::Socket::SSL->start_SSL($raw,
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2']) or die "start_SSL: $!";
    $s->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" . h2_frame(H2_SETTINGS, 0, 0, ''));
    $s->blocking(0);
    my $dl = Time::HiRes::time + 5 * TIMEOUT_MULT;
    while (Time::HiRes::time < $dl) {
        my $f = h2_read_frame($s, 0.3) or next;
        if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
            $s->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, '')); last;
        }
    }
    return $s;
}

# --- attack: several streams accumulating undispatched body (no END_STREAM),
#     each sending only within the flow-control window the server advertises.
#     The cap must RST a stream rather than let the sum grow past it.
{
    my $s = open_h2();
    my (%swin, @sids); my $conn_win = 65535;
    my $hdr = hpack_encode_headers([':method','POST'], [':scheme','https'],
                [':authority',"127.0.0.1:$port"], [':path','/up']);
    for my $k (0 .. 5) {
        my $sid = 1 + 2*$k; push @sids, $sid;
        $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid, $hdr));   # no END_STREAM
        $swin{$sid} = 65535;
    }
    my $payload = 'B' x $FRAME;
    my ($rst, $goaway) = (0, 0);
    my $drain = sub {
        while (my $f = h2_read_frame($s, 0.008)) {
            if ($f->{type} == H2_WINDOW_UPDATE) {
                my $inc = unpack('N', $f->{payload}) & 0x7fffffff;
                if ($f->{stream_id} == 0) { $conn_win += $inc }
                elsif (exists $swin{$f->{stream_id}}) { $swin{$f->{stream_id}} += $inc }
            }
            elsif ($f->{type} == H2_RST_STREAM) { $rst = 1; delete $swin{$f->{stream_id}} }
            elsif ($f->{type} == H2_GOAWAY)     { $goaway = 1; return }
        }
    };
    my $deadline = Time::HiRes::time + 40 * TIMEOUT_MULT;
    while (Time::HiRes::time < $deadline && !$rst && !$goaway) {
        $drain->(); last if $rst || $goaway;
        my $progress = 0;
        for my $sid (@sids) {
            next unless exists $swin{$sid};
            while ($swin{$sid} >= $FRAME && $conn_win >= $FRAME) {
                my $n = syswrite($s, h2_frame(H2_DATA, 0, $sid, $payload));
                last unless defined $n;
                $swin{$sid} -= $FRAME; $conn_win -= $FRAME; $progress = 1;
            }
        }
        $drain->();
        Time::HiRes::sleep(0.001) unless $progress;
    }
    close $s;
    ok $rst, 'a stream pushing the connection body sum past the cap is RST';
}

# --- legit: one upload comfortably under the cap is accepted and answered.
# Kept within the initial 65535 flow-control window (no WINDOW_UPDATE dance)
# and written blocking: a partial non-blocking TLS syswrite retried with a
# recomputed frame corrupts the stream (seen on OpenBSD's smaller buffers).
{
    my $s = open_h2();
    my $sid = 1;
    my $UP  = 60000;                     # < 65535 window, << 4MB cap
    my $hdr = hpack_encode_headers([':method','POST'], [':scheme','https'],
                [':authority',"127.0.0.1:$port"], [':path','/up'],
                ['content-length', "$UP"]);
    $s->blocking(1);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid, $hdr));
    my $left = $UP;
    while ($left > 0) {
        my $n = $left > $FRAME ? $FRAME : $left;   # <= SETTINGS_MAX_FRAME_SIZE
        my $end = ($left - $n == 0) ? FLAG_END_STREAM : 0;
        $s->syswrite(h2_frame(H2_DATA, $end, $sid, 'B' x $n));
        $left -= $n;
    }
    $s->blocking(0);
    my ($ok, $rst) = (0, 0);
    my $deadline = Time::HiRes::time + 30 * TIMEOUT_MULT;
    while (Time::HiRes::time < $deadline && !$ok && !$rst) {
        my $f = eval { h2_read_frame($s, 0.2) };
        next unless $f;
        $ok  = 1 if $f->{type} == H2_HEADERS;      # response headers = accepted
        $rst = 1 if $f->{type} == H2_RST_STREAM;
    }
    close $s;
    ok($ok && !$rst, 'a legit upload under the cap is accepted, not RST');
}

kill 'QUIT', $server;
waitpid $server, 0;
