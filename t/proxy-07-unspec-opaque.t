#!perl
# PROXY v2 UNSPEC's address field is opaque: padding that is not well-formed
# TLVs must not get a 400. INET/INET6 TLVs are still validated.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use IO::Socket::INET;

plan tests => 5;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_proxy_protocol(1);

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $b = 'addr=' . $env->{REMOTE_ADDR};
    return [200, ['Content-Length' => length $b, 'Connection' => 'close'], [$b]];
});

sub proxy_v2 {
    my ($fam_proto, $payload) = @_;
    return "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"
         . "\x21"                       # v2, PROXY
         . chr($fam_proto)
         . pack('n', length $payload)
         . $payload;
}

sub ask {
    my ($hdr) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
    ) or return undef;
    $s->print($hdr);
    $s->print("GET /u HTTP/1.1\015\012Host: l\015\012Connection: close\015\012\015\012");
    my $buf = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 6 * TMULT;
        while (1) {
            my $got = sysread($s, my $b, 65536);
            last unless $got;
            $buf .= $b;
        }
        alarm 0;
    };
    close $s;
    return $buf;
}

run_client("unspec-payload-ignored", sub {
    my $r = ask(proxy_v2(0x00, "\xff" x 12));   # not well-formed TLVs
    return 11 unless defined $r && length $r;
    return 12 unless $r =~ m{^HTTP/1\.[01] 200 }m;
    return 13 unless $r =~ /addr=127\.0\.0\.1/;
    return 0;
});

run_client("unspec-empty-and-inet-tail", sub {
    my $r = ask(proxy_v2(0x00, ''));
    return 21 unless defined $r && $r =~ m{^HTTP/1\.[01] 200 }m;
    my $inet = pack('NNnn', 0x0A000001, 0x0A000002, 40000, 80);
    $r = ask(proxy_v2(0x11, $inet . "\x03\x00"));  # 2-byte TLV tail
    return 22 unless defined $r && $r =~ m{^HTTP/1\.[01] 400 }m;
    return 0;
});
