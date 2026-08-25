#!perl
# HEADERS+RST_STREAM for one stream in a single write: the app then answers an
# orphaned stream, which must be a no-op rather than a croak that unwinds
# through the libev callback and kills the worker.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

my $probe = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support" unless $probe->has_tls();
plan skip_all => "Feersum not compiled with H2 support"  unless $probe->has_h2();
plan skip_all => "IO::Socket::SSL required"
    unless eval { require IO::Socket::SSL; 1 };

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert && -f $key;

plan tests => 5;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
eval { $feer->set_tls(cert_file => $cert, key_file => $key, h2 => 1) };
is $@, '', "set_tls with h2";

$feer->psgi_request_handler(sub {
    return [200, ['Content-Type' => 'text/plain'], ['ok']];
});

sub frame {
    my ($type, $flags, $sid, $payload) = @_;
    $payload = '' unless defined $payload;
    return pack('C3', (length($payload) >> 16) & 0xff,
                      (length($payload) >>  8) & 0xff,
                       length($payload)        & 0xff)
         . chr($type) . chr($flags) . pack('N', $sid & 0x7fffffff) . $payload;
}

# :method GET (static 2), :path / (static 4), :scheme https (static 7),
# then :authority (static name 1) as a literal with incremental indexing.
use constant HPACK_GET => "\x82\x84\x87\x01\x09localhost";
use constant PREFACE   => "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

sub h2_connect {
    my $s = IO::Socket::SSL->new(
        PeerAddr => '127.0.0.1', PeerPort => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2'],
        Timeout => 5 * TMULT,
    ) or return undef;
    $s->blocking(0);
    syswrite($s, PREFACE . frame(0x4, 0, 0, ''));   # preface + empty SETTINGS
    select undef, undef, undef, 0.3 * TMULT;
    sysread($s, my $ignored, 65536);                 # server SETTINGS
    syswrite($s, frame(0x4, 1, 0, ''));              # SETTINGS ACK
    return $s;
}

run_client("h2-headers-plus-rst", sub {
    # 1. attack: request and reset the same stream in a single write
    my $s = h2_connect() or return 10;
    syswrite($s, frame(0x1, 0x5, 1, HPACK_GET)      # HEADERS END_STREAM|END_HEADERS
                . frame(0x3, 0, 1, pack('N', 8)));  # RST_STREAM CANCEL
    select undef, undef, undef, 1.0 * TMULT;        # let the app run
    close $s;

    # 2. the server must still be serving: a fresh h2 request gets a response
    my $s2 = h2_connect() or return 11;
    syswrite($s2, frame(0x1, 0x5, 3, HPACK_GET));
    my ($got, $saw_headers) = ('', 0);
    for (1 .. 30 * TMULT) {
        select undef, undef, undef, 0.1;
        my $n = sysread($s2, my $buf, 65536);
        $got .= $buf if defined $n && $n > 0;
        # walk the frame list looking for HEADERS (type 0x1) on our stream
        my $off = 0;
        while ($off + 9 <= length $got) {
            my ($hi, $mid, $lo, $type, undef, $sid) =
                unpack 'C3 C C N', substr($got, $off, 9);
            my $len = ($hi << 16) | ($mid << 8) | $lo;
            last if $off + 9 + $len > length $got;
            $saw_headers = 1 if $type == 0x1 && ($sid & 0x7fffffff) == 3;
            $off += 9 + $len;
        }
        last if $saw_headers;
    }
    close $s2;
    return 12 unless length $got;                   # no answer: worker is gone
    return 13 unless $saw_headers;                  # answered, but not our request
    return 0;
});

pass "server survived HEADERS+RST_STREAM";
