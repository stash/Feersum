#!perl
# PROXY protocol v2 TLV semantics: psgi.url_scheme is "https" only when the
# PP2_TYPE_SSL TLV has the PP2_CLIENT_SSL bit set, not merely when the TLV is
# present, and psgix.proxy_tlvs is a per-request copy so an app mutating it
# cannot corrupt later requests on the same connection.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use IO::Socket::INET;

plan tests => 9;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
$feer->set_proxy_protocol(1);

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $tlvs = $env->{'psgix.proxy_tlvs'} || {};
    my $b = 'scheme=' . $env->{'psgi.url_scheme'}
          . ' t2=' . (defined $tlvs->{2} ? $tlvs->{2} : '-');
    # mutate, to prove the next request on this connection is unaffected
    $tlvs->{2} = 'MUTATED';
    return [200, ['Content-Length' => length $b], [$b]];
});

# PROXY v2: signature, ver/cmd, fam/proto, len, then addresses, then TLVs.
sub proxy_v2 {
    my ($tlv_payload) = @_;
    $tlv_payload = '' unless defined $tlv_payload;
    my $addrs = pack('NNnn', 0x0A000001, 0x0A000002, 40000, 80);  # src,dst,sport,dport
    my $body  = $addrs . $tlv_payload;
    return "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"
         . "\x21"                       # v2, PROXY
         . "\x11"                       # AF_INET, STREAM
         . pack('n', length $body)
         . $body;
}
sub tlv { my ($type, $val) = @_; return chr($type) . pack('n', length $val) . $val }

sub ask {
    my ($hdr, $n) = @_;
    $n ||= 1;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
    ) or return ();
    $s->print($hdr);
    my @out;
    for my $i (1 .. $n) {
        my $last = ($i == $n);
        $s->print("GET /r$i HTTP/1.1\015\012Host: l\015\012"
                . ($last ? "Connection: close\015\012" : '') . "\015\012");
        my $buf = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 6 * TMULT;
            while ($buf !~ /\015\012\015\012.{5}/s) {
                my $got = sysread($s, my $b, 65536);
                last unless $got;
                $buf .= $b;
            }
            alarm 0;
        };
        push @out, $buf;
        $buf = '';
    }
    close $s;
    return @out;
}

# PP2_TYPE_SSL = 0x20; value = client byte + 4-byte verify
my $auth = tlv(0x02, 'orig-authority');

run_client("ssl-tlv-client-bit-clear", sub {
    my ($r) = ask(proxy_v2($auth . tlv(0x20, "\x00" . "\0\0\0\0")));
    return 11 unless defined $r && length $r;
    return 12 unless $r =~ /scheme=http\b/;      # pre-fix: https
    return 0;
});

run_client("ssl-tlv-client-bit-set", sub {
    my ($r) = ask(proxy_v2($auth . tlv(0x20, "\x01" . "\0\0\0\0")));
    return 11 unless defined $r && length $r;
    return 12 unless $r =~ /scheme=https\b/;
    return 0;
});

run_client("ssl-tlv-cert-conn-only", sub {
    # 0x02 = PP2_CLIENT_CERT_CONN without PP2_CLIENT_SSL
    my ($r) = ask(proxy_v2($auth . tlv(0x20, "\x02" . "\0\0\0\0")));
    return 11 unless defined $r && length $r;
    return 12 unless $r =~ /scheme=http\b/;      # pre-fix: https
    return 0;
});

run_client("tlvs-not-shared-across-requests", sub {
    my @r = ask(proxy_v2($auth), 3);
    return 11 unless @r == 3 && length $r[2];
    # every request must see the original value despite request 1 mutating it
    for my $i (0 .. 2) {
        return 12 + $i unless $r[$i] =~ /t2=orig-authority/;
    }
    return 0;
});
