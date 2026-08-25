#!perl
# The TLS read path re-implements the plain H1 read/parse choke: the same
# response shapes on both listeners of one server must give identical results.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $evh = Feersum->new_instance();
plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;
eval { require IO::Socket::SSL; 1 } or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my $BIG = 1_000_000;

my @cases = (
    ['simple GET',       "GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
    ['204 bodyless',     "GET /204 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
    ['HEAD',             "HEAD /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
    ['streamed chunked', "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
    ['HTTP/1.0 stream',  "GET /stream HTTP/1.0\r\n\r\n"],
    ['large response',   "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
    ['pipelined x3',     ("GET /ok HTTP/1.1\r\nHost: x\r\n\r\n") x 2
                         . "GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
    ['content-length body',
                         "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n"
                         . "Connection: close\r\n\r\nhello"],
    ['chunked body',     "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n"
                         . "Connection: close\r\n\r\n5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n"],
    ['over-long URI',    "GET /" . ('u' x 4000) . " HTTP/1.1\r\nHost: x\r\n"
                         . "Connection: close\r\n\r\n"],
    ['bad request line', "NOTAMETHOD\r\n\r\n"],
);
plan tests => 2 + scalar(@cases);

my ($psock, $pport) = get_listen_socket();
my ($tsock, $tport) = get_listen_socket();
ok $psock && $tsock, "listen sockets (plain $pport, tls $tport)";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($psock);
    $f->use_socket($tsock);
    $f->set_keepalive(1);
    $f->read_timeout(10 * TIMEOUT_MULT);
    $f->header_timeout(10 * TIMEOUT_MULT);
    $f->write_timeout(10 * TIMEOUT_MULT);
    $f->max_uri_len(2000);
    # h2 => 0: this compares the two H1 twins, not H1 against H2.
    eval { $f->set_tls(listener => 1, cert_file => $cert_file,
                       key_file => $key_file, h2 => 0) };
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $p = $env->{PATH_INFO} // q{};
        if ($p eq '/echo') {
            my $b = q{};
            $env->{'psgi.input'}->read($b, $env->{CONTENT_LENGTH} || 0)
                if $env->{CONTENT_LENGTH};
            return [200, ['Content-Type' => 'text/plain'], ['got=' . length $b]];
        }
        return [204, [], []] if $p eq '/204';
        return [200, ['Content-Type' => 'text/plain'], ['x' x $BIG]] if $p eq '/big';
        if ($p eq '/stream') {
            return sub {
                my $w = shift->([200, ['Content-Type' => 'text/plain']]);
                $w->write("chunk$_") for 1 .. 5;
                $w->close;
            };
        }
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $psock;
close $tsock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

sub xact {
    my ($kind, $req) = @_;
    my $s = $kind eq 'tls'
        ? IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$tport",
              SSL_verify_mode => 0, Timeout => 10 * TIMEOUT_MULT)
        : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$pport",
              Timeout => 10 * TIMEOUT_MULT);
    return 'CONNFAIL' unless $s;
    my $buf = q{};
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 40 * TIMEOUT_MULT;
        print {$s} $req;
        while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $buf .= $z }
        alarm 0;
        1;
    } or $buf .= '[TIMEOUT]';
    alarm 0;
    close $s;
    return $buf;
}

sub summarize {
    my ($r) = @_;
    my ($h, $b) = split /\r\n\r\n/, $r, 2;
    $h //= q{};
    $b //= q{};
    my @st = $r =~ m{^HTTP/1\.[01][ ](\d+)}mg;
    my ($cl) = $h =~ /^Content-Length:\s*(\d+)/mi;
    return sprintf 'status=%s chunked=%s cl=%s bodylen=%d%s',
        (@st ? "@st" : 'none'), ($h =~ /chunked/i ? 'y' : 'n'),
        (defined $cl ? $cl : q{-}), length $b,
        ($r =~ /\Q[TIMEOUT]\E/ ? ' TIMEOUT' : q{});
}

for my $c (@cases) {
    my ($name, $req) = @$c;
    my $plain = summarize(xact('plain', $req));
    my $tls   = summarize(xact('tls',   $req));
    is $tls, $plain, "plain and TLS agree: $name";
}

# The large response is the one that regressed before, so assert its size
# outright rather than only that the twins agree (they could agree on wrong).
like summarize(xact('tls', "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")),
    qr/bodylen=$BIG\b/, "TLS delivers the whole $BIG byte body";

reap_server($server);
