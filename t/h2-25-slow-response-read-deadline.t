#!perl
# A dispatched H2 stream must not be reaped by the parent connection's read
# deadline while its response is still being produced: the same slow-response
# app over H1, TLS and H2 delivers every chunk.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use AnyEvent;
use H2Utils;
use IO::Socket::INET;
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

plan tests => 4;

my $RD     = 2 * TIMEOUT_MULT;   # read_timeout
my $CHUNKS = 8;
my $GAP    = 0.35 * TIMEOUT_MULT; # whole response needs ~2.8x read_timeout

# Same app every time; only the transport changes.
sub spawn {
    my ($mode) = @_;
    my ($lsock, $lport) = get_listen_socket();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        no warnings 'once';
        $Feersum::DIED = sub { };
        my $f = Feersum->new_instance();
        $f->use_socket($lsock);
        $f->read_timeout($RD);
        $f->header_timeout($RD);
        # write_timeout left at 0 on purpose: this is the READ deadline.
        if ($mode ne 'h1plain') {
            eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key,
                               h2 => ($mode eq 'h2' ? 1 : 0)) };
        }
        my @held;
        $f->psgi_request_handler(sub {
            return sub {
                my $w = shift->([200, ['Content-Type' => 'text/plain']]);
                my $i = 0;
                my $t;
                $t = EV::timer $GAP, $GAP, sub {
                    if ($i >= $CHUNKS) { undef $t; $w->close; return }
                    $w->write(sprintf('CHUNK-%02d;', $i++));
                };
                push @held, [$w, \$t];
            };
        });
        my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $lsock;
    return ($pid, $lport);
}

sub chunks_over_h1 {
    my ($port, $tls) = @_;
    my $s = $tls
        ? IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", SSL_verify_mode => 0,
              SSL_alpn_protocols => ['http/1.1'], Timeout => 10 * TIMEOUT_MULT)
        : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
              Timeout => 10 * TIMEOUT_MULT);
    return -1 unless $s;
    print {$s} "GET /slow HTTP/1.1\r\nHost: x\r\n\r\n";
    my $raw = '';
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 40 * TIMEOUT_MULT;
        while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $raw .= $z }
        alarm 0;
        1;
    };
    alarm 0;
    close $s;
    return scalar(() = $raw =~ /CHUNK-\d\d;/g);
}

sub chunks_over_h2 {
    my ($port) = @_;
    my $s = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2'], Timeout => 10 * TIMEOUT_MULT);
    return -1 unless $s;
    $s->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" . h2_frame(H2_SETTINGS, 0, 0, ''));
    $s->blocking(0);
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($s, 1) or last;
        if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
            $s->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
            last;
        }
    }
    my $h = hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
        [':authority', "127.0.0.1:$port"], [':path', '/slow']);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $h));
    # Read and say NOTHING further - an SSE client's shape.  Sending anything
    # (even WINDOW_UPDATEs) would reset the parent read timer and hide this.
    my ($body, $t0) = ('', Time::HiRes::time());
    while (Time::HiRes::time() - $t0 < 40 * TIMEOUT_MULT) {
        my $f = h2_read_frame($s, 0.3) or next;
        $body .= $f->{payload} if $f->{type} == H2_DATA;
        last if $f->{type} == H2_GOAWAY || $f->{type} == H2_RST_STREAM;
        last if $f->{type} == H2_DATA && ($f->{flags} & FLAG_END_STREAM);
    }
    close $s;
    return scalar(() = $body =~ /CHUNK-\d\d;/g);
}

my %got;
for my $mode (qw(h1plain h1tls h2)) {
    my ($pid, $port) = spawn($mode);
    select undef, undef, undef, 1 * TIMEOUT_MULT;
    $got{$mode} = $mode eq 'h2' ? chunks_over_h2($port) : chunks_over_h1($port, $mode eq 'h1tls');
    reap_server($pid);
}

is $got{h1plain}, $CHUNKS, "plain HTTP/1.1 delivers all $CHUNKS chunks";
is $got{h1tls},   $CHUNKS, "HTTP/1.1 over TLS delivers all $CHUNKS chunks";
is $got{h2}, $CHUNKS,
    sprintf('HTTP/2 delivers all %d chunks too: a response slower than '
          . 'read_timeout=%ds is not reaped while it is producing (got %s)',
            $CHUNKS, $RD, $got{h2});
is $got{h2}, $got{h1plain},
    'and the three transports agree, which is the actual contract';
