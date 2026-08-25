#!perl
# A zero-length write (an empty $w->write() outside the handler, or an IO-handle
# body whose getline returns q{}) must not truncate or desync the response on
# plain or TLS: write()/writev() returning 0 is not an I/O error.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
my $has_tls = $probe->has_tls();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
my $tls_ok = $has_tls && -f $cert && -f $key
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

# Fixed count: the TLS leg is a SKIP, which still emits its one test.
plan tests => 5;

my ($psock, $pport) = get_listen_socket();
my ($tsock, $tport) = get_listen_socket();
ok $psock && $tsock, 'listen sockets';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($psock);
    $f->use_socket($tsock);
    $f->set_keepalive(1);
    $f->read_timeout(20 * TIMEOUT_MULT);
    $f->header_timeout(20 * TIMEOUT_MULT);
    $f->write_timeout(20 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 1, cert_file => $cert, key_file => $key, h2 => 0) }
        if $tls_ok;
    my %keep;
    $f->request_handler(sub {
        my $r = shift;
        my $p = $r->env->{PATH_INFO} // q{};
        if ($p eq '/second') {
            $r->send_response(200, ['Content-Type' => 'text/plain'], ['SECOND']);
            return;
        }
        # Content-Length known => not chunked, so each write is its own iovec.
        # Writing from a timer keeps the ring empty, so the empty write is
        # alone in its batch - the shape that returned 0 from write().
        my $w = $r->start_streaming(200,
            ['Content-Type' => 'text/plain', 'Content-Length' => 6]);
        my @parts = ('abc', q{}, 'def');
        my $i = 0;
        my $t;
        $t = EV::timer 0.05, 0.05, sub {
            if ($i > $#parts) { undef $t; delete $keep{0 + $w}; $w->close; return }
            $w->write($parts[ $i++ ]);
        };
        $keep{0 + $w} = [$w, \$t];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $psock;
close $tsock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

sub fetch {
    my ($kind, $pipeline) = @_;
    my $s = $kind eq 'tls'
        ? IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$tport",
              SSL_verify_mode => 0, Timeout => 8 * TIMEOUT_MULT)
        : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$pport",
              Timeout => 8 * TIMEOUT_MULT);
    return q{} unless $s;
    my $req = "GET /stream HTTP/1.1\r\nHost: x\r\n"
        . ($pipeline
            ? "\r\nGET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
            : "Connection: close\r\n\r\n");
    my $buf = q{};
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 20 * TIMEOUT_MULT;
        print {$s} $req;
        while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $buf .= $z }
        alarm 0;
        1;
    };
    alarm 0;
    close $s;
    return $buf;
}
sub split_resp {
    my ($r) = @_;
    my ($h, $b) = split /\r\n\r\n/, $r, 2;
    return ($h // q{}, $b // q{});
}

{
    my ($h, $b) = split_resp(fetch('plain', 0));
    is $b, 'abcdef', 'plain: an empty write does not truncate the response';
}

SKIP: {
    skip 'no TLS', 1 unless $tls_ok;
    my ($h, $b) = split_resp(fetch('tls', 0));
    is $b, 'abcdef', 'TLS: same response (the twins agree)';
}

{
    # Desync check: the declared Content-Length must cover exactly the body,
    # with the pipelined response starting immediately after it.
    my ($h, $b) = split_resp(fetch('plain', 1));
    my ($cl) = $h =~ /^Content-Length:\s*(\d+)/mi;
    is +(defined $cl ? substr($b, 0, $cl) : $b), 'abcdef',
        'keepalive: first body is exactly its Content-Length';
    like +(defined $cl ? substr($b, $cl) : q{}), qr{^HTTP/1\.1 },
        'keepalive: the next response begins where the body ends (no desync)';
}

reap_server($server);
