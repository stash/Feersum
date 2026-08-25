#!perl
# H2 matches H1 when features combine: a PSGI IO-handle body is paced by the
# pump so a large file does not go resident (WINDOW_UPDATEs get read), and the
# header-count and header-name-length limits answer 431, not a stream reset.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use H2Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with HTTP/2 support' unless $probe->has_h2();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
my $curl = `curl --version 2>/dev/null`;
plan skip_all => 'curl not available'  unless $curl;
plan skip_all => 'curl lacks HTTP/2'   unless $curl =~ /\bHTTP2\b/;
plan skip_all => 'needs /proc for RSS' unless -r "/proc/$$/status";

plan tests => 10;

my $dir = tempdir(CLEANUP => 1);
my $MB  = 40;
my $file = "$dir/body.bin";
open my $bf, '>', $file or die $!;
print {$bf} ('Z' x (1024 * 1024)) for 1 .. $MB;
close $bf;
my $SIZE = -s $file;

my ($psock, $pport) = get_listen_socket();
my ($tsock, $tport) = get_listen_socket();
ok $psock && $tsock, 'listen sockets';

my $pidfile = "$dir/srv.pid";
my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', "$dir/srv.out";
    open STDERR, '>', "$dir/srv.log";
    if (open my $pf, '>', $pidfile) { print {$pf} "$$\n"; close $pf }
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($psock);
    $f->use_socket($tsock);
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    $f->write_timeout(60 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 1, cert_file => $cert, key_file => $key, h2 => 1) };
    $f->psgi_request_handler(sub {
        my $env = shift;
        return [200, ['Content-Type' => 'text/plain'], ['ok']]
            if ($env->{PATH_INFO} // q{}) eq '/ok';
        open my $fh, '<', $file
            or return [500, ['Content-Type' => 'text/plain'], ['no file']];
        binmode $fh;
        return [200, ['Content-Type' => 'application/octet-stream'], $fh];
    });
    my $life_timer = EV::timer(180 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $psock;
close $tsock;

my $srvpid;
for (1 .. 60) {
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
    if (open my $h, '<', $pidfile) { chomp($srvpid = <$h> // q{}); close $h; last if $srvpid }
}
ok $srvpid, 'server reported its pid';

sub vmhwm {
    open my $h, '<', "/proc/$srvpid/status" or return -1;
    my $v = -1;
    while (<$h>) { $v = $1 if /VmHWM:\s+(\d+)/ }
    close $h;
    return $v;
}
my $max = 90 * TIMEOUT_MULT;
sub fetch_size {
    my ($proto, $url) = @_;
    return 0 + `curl -sS -k $proto --max-time $max -o /dev/null -w '%{size_download}' '$url' 2>/dev/null`;
}

# H1 first: it establishes the baseline high-water mark for this process.
is fetch_size('--http1.1', "http://127.0.0.1:$pport/f"), $SIZE,
    'plain H1 delivers the whole IO-handle body';
is fetch_size('--http1.1', "https://127.0.0.1:$tport/f"), $SIZE,
    'TLS H1 delivers the whole IO-handle body';

my $before = vmhwm();
is fetch_size('--http2', "https://127.0.0.1:$tport/f"), $SIZE,
    'H2 delivers the whole IO-handle body';
my $growth = vmhwm() - $before;

# Both sides in kB: VmHWM is kB, $SIZE is bytes.  Buffering the body costs
# about its size; pacing costs a few hundred kB.  A quarter of the body sits
# far above the paced cost and far below the bug.
cmp_ok $growth, '<', ($SIZE / 1024) / 4,
    sprintf('H2 IO-handle body is paced, not buffered (RSS grew %d kB for a %d MB body)',
            $growth, $MB);

# Header limits: 431 on every transport, not a bare stream reset.
my $many = join q{ }, map { "-H 'X-H$_: v'" } 1 .. 80;
my $long = "-H '" . ('L' x 202) . ": v'";
for my $c (['too many headers', $many], ['over-long header name', $long]) {
    my ($what, $hdrs) = @$c;
    my $code = `curl -sS -k --http2 --max-time $max -o /dev/null -w '%{http_code}' $hdrs 'https://127.0.0.1:$tport/ok' 2>/dev/null`;
    is $code, '431', "H2 answers 431 for $what, rather than resetting the stream";
}

# The limit check runs before Extended CONNECT detection, so an over-limit
# CONNECT is answered 431 instead of dispatched with a truncated header set.
# Raw H2 CONNECT on purpose: curl sends an HTTP/1.1 Upgrade for wss:// URLs,
# which the H1 path answers 431 whether or not the H2 ordering is right.
SKIP: {
    # h2_connect pulls in IO::Socket::SSL at runtime; some smokers have it
    # unusable (Net::SSLeay fails to load), which killed the whole file here
    # rather than skipping this one case.  Everything above uses curl.
    skip 'IO::Socket::SSL not usable', 1
        unless eval { require IO::Socket::SSL; 1 };
    my $sock = h2_connect($tport);
    if (!$sock) { fail 'raw H2 connection for the CONNECT case' }
    else {
        my $hdrs = hpack_encode_headers(
            [':method', 'CONNECT'], [':protocol', 'websocket'],
            [':path', '/c'], [':scheme', 'https'],
            [':authority', "127.0.0.1:$tport"],
            map { [ "x-h$_", 'v' ] } 1 .. 80);
        $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdrs));
        my $status = 0;
        my $dl = time + 10 * TIMEOUT_MULT;
        while (time < $dl) {
            my $fr = h2_read_frame($sock, $dl - time) or last;
            next unless $fr->{type} == H2_HEADERS && $fr->{stream_id} == 1;
            $status = hpack_decode_status($fr->{payload});
            last;
        }
        close $sock;
        is $status, 431,
            'an over-limit Extended CONNECT is refused, not dispatched to the app';
    }
}

# H1 says "Request header fields too large" for this; H2 reused the 413 body
# text, diverging in exactly the place the 431 change set out to harmonise.
like
    scalar `curl -sS -k --http2 --max-time $max $many 'https://127.0.0.1:$tport/ok' 2>/dev/null`,
    qr/header fields too large/i,
    'the H2 431 body names the header limit, not the body limit';

reap_server($server);
