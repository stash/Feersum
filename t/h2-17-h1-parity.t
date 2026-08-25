#!perl
# H1 and H2 have separate response paths: the same matrix of response shapes
# down both (listener 0 plain H1, listener 1 TLS+h2) must agree on status and
# payload bytes.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use AnyEvent;
use H2Utils;
use Feersum;
use Socket ();

# sysread on a blocking socket waits forever regardless of any deadline the
# caller is tracking, so a server that stops answering wedges the whole run
# instead of failing.  Bound every read at the socket.
sub rcv_timeout {
    my ($sock, $secs) = @_;
    return $sock unless $sock;
    setsockopt $sock, Socket::SOL_SOCKET(), Socket::SO_RCVTIMEO(),
        pack('l!l!', $secs, 0);
    return $sock;
}

my $probe = Feersum->new();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();

my ($cert, $key) = ('t/certs/alpha.crt', 't/certs/alpha.key');
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 4;

my $seed = defined $ENV{FEERSUM_FUZZ_SEED}
    ? srand($ENV{FEERSUM_FUZZ_SEED}) : srand();
diag("fuzz seed $seed (set FEERSUM_FUZZ_SEED=$seed to reproduce)");
my $ITERS = $ENV{FEERSUM_FUZZ_ITERS} || 40;

my @STATUS = (200, 201, 202, 204, 205, 206, 300, 304, 400, 404, 500, 503);
my @MODES  = qw(array stream);

my ($h1_sock, $h1_port) = get_listen_socket();
my ($h2_sock, $h2_port) = get_listen_socket();
ok $h1_sock && $h2_sock, "listen sockets: h1=$h1_port h2=$h2_port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    my $f = Feersum->new();
    $f->use_socket($h1_sock);    # listener 0: plain
    $f->use_socket($h2_sock);    # listener 1: TLS + h2
    $f->set_tls(listener => 1, h2 => 1, cert_file => $cert, key_file => $key);
    $f->set_keepalive(1);
    $f->read_timeout(20 * TIMEOUT_MULT);
    $f->write_timeout(20 * TIMEOUT_MULT);
    $f->header_timeout(20 * TIMEOUT_MULT);
    our @keep;
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $status = $env->{HTTP_X_STATUS} || 200;
        my $nh     = $env->{HTTP_X_NHDRS}  || 0;
        my $mode   = $env->{HTTP_X_MODE}   || 'array';
        my @body   = map { 'x' x $_ } grep { length }
                     split /,/, ($env->{HTTP_X_CHUNKS} // q{});
        my @hdrs   = ('Content-Type' => 'text/plain');
        push @hdrs, ("X-Pad-$_" => ('p' x (($_ * 7) % 40 + 1))) for 1 .. $nh;
        if ($mode eq 'stream') {
            return sub {
                my $respond = shift;
                my $w = $respond->([$status, \@hdrs]);
                push @keep, $w;
                $w->write($_) for @body;
                $w->close;
            };
        }
        return [$status, \@hdrs, \@body];
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $h1_sock;
close $h2_sock;

sub spec_headers {
    my ($status, $nh, $chunks, $mode) = @_;
    return (['x-status', "$status"], ['x-nhdrs', "$nh"],
            ['x-chunks', $chunks], ['x-mode', $mode]);
}

# H1: read the whole close-delimited response, dechunking a streamed body so the
# comparison is of payload bytes rather than transfer framing.
sub h1_answer {
    my ($status, $nh, $chunks, $mode, $head) = @_;
    my $s = rcv_timeout(
        IO::Socket::INET->new(PeerAddr => "127.0.0.1:$h1_port", Proto => 'tcp',
                              Timeout => 10 * TIMEOUT_MULT), 15 * TIMEOUT_MULT)
        or return;
    my $m = $head ? 'HEAD' : 'GET';
    syswrite $s, "$m /r HTTP/1.1\r\nHost: x\r\nX-Status: $status\r\nX-Nhdrs: $nh\r\n"
               . "X-Chunks: $chunks\r\nX-Mode: $mode\r\nConnection: close\r\n\r\n";
    my ($buf, $g) = (q{});
    while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
    close $s;
    my ($st) = $buf =~ m{^HTTP/1\.\d\ (\d{3})}x;
    my ($head_blk, $body) = split /\r\n\r\n/, $buf, 2;
    $body = q{} unless defined $body;
    if (($head_blk // q{}) =~ /^Transfer-Encoding:\s*chunked/mi) {
        my ($dec, $pos) = (q{}, 0);
        while ($pos < length $body) {
            my $nl = index $body, "\r\n", $pos;
            last if $nl < 0;
            my ($hex) = substr($body, $pos, $nl - $pos) =~ /^([0-9a-fA-F]+)/ or last;
            my $sz = hex $hex;
            last if $sz == 0;
            $dec .= substr $body, $nl + 2, $sz;
            $pos = $nl + 2 + $sz + 2;
        }
        $body = $dec;
    }
    return ($st, $body);
}

sub h2_answer {
    my ($status, $nh, $chunks, $mode, $head) = @_;
    my ($sock) = h2_connect($h2_port, timeout => 10 * TIMEOUT_MULT);
    return unless $sock;
    my $hdrs = hpack_encode_headers(
        [':method', $head ? 'HEAD' : 'GET'], [':scheme', 'https'],
        [':authority', '127.0.0.1'], [':path', '/r'],
        spec_headers($status, $nh, $chunks, $mode));
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $hdrs));
    my ($st, $body, $done) = (undef, q{}, 0);
    my $deadline = time + 15 * TIMEOUT_MULT;
    while (!$done && time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time) or last;
        next unless $f->{stream_id} == 1 || $f->{stream_id} == 0;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $st = hpack_decode_status($f->{payload});
            $done = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        elsif ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $body .= $f->{payload};
            $done = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        elsif ($f->{type} == H2_RST_STREAM && $f->{stream_id} == 1) { $done = 1 }
        elsif ($f->{type} == H2_GOAWAY) { $done = 1 }
    }
    close $sock;
    return ($st, $body);
}

my (@missing, @status_diff, @body_diff);
for my $i (1 .. $ITERS) {
    my $status = $STATUS[ rand @STATUS ];
    my $mode   = $MODES[ rand @MODES ];
    my $nh     = int rand 3;
    my @lens   = map { int rand 50 } 1 .. int(rand 4);
    my $chunks = join q{,}, @lens;
    my $head   = (rand() < 0.25) ? 1 : 0;
    my $desc   = "i=$i status=$status mode=$mode nh=$nh chunks=[$chunks] "
               . ($head ? 'HEAD' : 'GET');

    my ($s1, $b1) = h1_answer($status, $nh, $chunks, $mode, $head);
    my ($s2, $b2) = h2_answer($status, $nh, $chunks, $mode, $head);
    if (!defined $s1) { push @missing, "$desc: H1 gave no response"; next }
    if (!defined $s2) { push @missing, "$desc: H2 gave no response"; next }
    push @status_diff, "$desc: h1=$s1 h2=$s2" if $s1 != $s2;
    push @body_diff, sprintf('%s: h1=%d bytes h2=%d bytes', $desc,
                             length($b1 // q{}), length($b2 // q{}))
        if ($b1 // q{}) ne ($b2 // q{});
}

reap_server($server);

is scalar(@missing), 0, "$ITERS shapes: both transports answered every request"
    or diag join "\n", @missing[0 .. ($#missing > 4 ? 4 : $#missing)];
is scalar(@status_diff), 0, 'H1 and H2 agree on the status for every shape'
    or diag join "\n", @status_diff[0 .. ($#status_diff > 4 ? 4 : $#status_diff)];
is scalar(@body_diff), 0, 'H1 and H2 deliver identical payload bytes for every shape'
    or diag join "\n", @body_diff[0 .. ($#body_diff > 4 ? 4 : $#body_diff)];
