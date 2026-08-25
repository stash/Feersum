#!perl
# return_from_io()/return_from_psgix_io() croaks on a handle other than the one
# it gave out (anything else splices foreign bytes into rbuf and re-arms a
# cross-connection close); a PROXY v2 TLV block with a 1-2 byte tail is rejected.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 6;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use Feersum;

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    our @held;
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->set_proxy_protocol(1);
    $f->read_timeout(15 * TIMEOUT_MULT);
    $f->header_timeout(15 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $p = $env->{PATH_INFO} // q{};
        if ($p eq '/wrong') {
            return sub {
                my $respond = shift;
                my $io = $env->{'psgix.io'};       # legitimate takeover
                push @held, $io;
                # Hand back a DIFFERENT handle than the one we were given.
                open my $other, '<', '/dev/null' or die "open: $!";
                my $err = q{};
                eval { $env->{'psgi.input'}->return_from_psgix_io($other); 1 }
                    or $err = $@ // 'died';
                $err =~ s/\s+\z//;
                $err = 'NO-CROAK' unless length $err;
                syswrite $io, "HTTP/1.1 200 OK\r\nContent-Length: "
                            . length($err) . "\r\n\r\n$err";
            };
        }
        return [200, ['Content-Type' => 'text/plain'], ['plain']];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

# A minimal well-formed PROXY v2 INET header, with an optional TLV block.
sub proxy_v2 {
    my ($tlv) = @_;
    $tlv = q{} unless defined $tlv;
    my $addr = pack('NNnn', 0x7f000001, 0x7f000001, 12345, 80);
    return "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A"
         . "\x21\x11" . pack('n', length($addr) + length $tlv) . $addr . $tlv;
}

# Keepalive is on and the takeover path never closes, so read to a complete
# Content-Length-delimited response rather than to EOF.
sub talk {
    my ($payload) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 8 * TIMEOUT_MULT) or return;
    syswrite $s, $payload;
    my $buf = q{};
    my $deadline = time + 10 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $rin = q{};
        vec($rin, fileno($s), 1) = 1;
        last unless select $rin, undef, undef, 1;
        my $g = sysread $s, my $z, 65536;
        last if !defined $g || $g == 0;
        $buf .= $z;
        if ($buf =~ /\r\n\r\n/) {
            my ($head, $body) = split /\r\n\r\n/, $buf, 2;
            my ($cl) = $head =~ /^Content-Length:\s*(\d+)/mi;
            last if defined $cl && length($body) >= $cl;
            last if !defined $cl;
        }
    }
    close $s;
    return $buf;
}

# --- 1. wrong handle handed back ---
my $got = talk(proxy_v2() . "GET /wrong HTTP/1.1\r\nHost: x\r\n\r\n");
like $got // q{}, qr{^HTTP/1\.1\ 200}x, 'takeover endpoint answered';
my ($body) = ($got // q{}) =~ /\r\n\r\n(.*)\z/s;
isnt $body, 'NO-CROAK', 'return_from_psgix_io rejected the wrong handle'
    or diag 'it accepted a handle wrapping a different descriptor';
like $body // q{}, qr/does not wrap this connection/,
    'and said why' or diag "croak was: " . ($body // 'undef');

# --- 2. PROXY v2 trailing TLV fragment ---
# One valid TLV (type 0x03, 1 byte) then a 2-byte tail that cannot be a header.
my $good_tlv = "\x03" . pack('n', 1) . "\xff";
my $ok_resp  = talk(proxy_v2($good_tlv)
                  . "GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
like $ok_resp // q{}, qr{^HTTP/1\.1\ 200}x,
    'a well-formed TLV block is still accepted';

my $bad_resp = talk(proxy_v2($good_tlv . "\x01\x02")
                  . "GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
like $bad_resp // q{}, qr{^HTTP/1\.[01]\ 4\d\d}x,
    'a trailing 1-2 byte TLV fragment is rejected, not silently dropped'
    or diag 'response was: ' . substr($bad_resp // 'none', 0, 60);

reap_server($server);
