#!perl
# An app dying inside a streaming callback seals the response dirty (H1: close
# with no terminator; H2: RST_STREAM) so no client mistakes it for complete.
# A stale $@ from a caught inner eval, or a close before the die, is unaffected.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 11;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe  = Feersum->new_instance();
my $cert   = 'eg/ssl-proxy/server.crt';
my $key    = 'eg/ssl-proxy/server.key';
my $curl   = `curl --version 2>/dev/null`;
my $nghttp = `which nghttp 2>/dev/null`; chomp $nghttp;
my $tls_ok = $probe->has_tls() && -f $cert && -f $key && $curl;
my $h2_ok  = $probe->has_tls() && $probe->has_h2() && -f $cert && -f $key
          && $nghttp && -x $nghttp;

my $dir = tempdir(CLEANUP => 1);
my ($psock, $pport) = get_listen_socket();   # PSGI, plain
my ($tsock, $tport) = get_listen_socket();   # PSGI, TLS+H2
my ($nsock, $nport) = get_listen_socket();   # native, plain
ok $psock && $tsock && $nsock, 'listen sockets';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once', 'redefine';
    *Feersum::DIED = sub {
        open my $fh, '>>', "$dir/died.log" or return;
        print {$fh} $_[0];
        close $fh;
    };
    my $f = Feersum->new_instance();
    $f->use_socket($psock);
    $f->use_socket($tsock);
    $f->set_keepalive(1);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->header_timeout(30 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 1, cert_file => $cert, key_file => $key,
                       $probe->has_h2 ? (h2 => 1) : ()) } if $tls_ok || $h2_ok;
    $f->psgi_request_handler(sub {
        my $env  = shift;
        my $path = $env->{PATH_INFO};
        return sub {
            my $respond = shift;
            my $w = $respond->([200, ['Content-Type' => 'text/plain']]);
            if ($path eq '/die-after-write') {
                $w->write('part1-');
                die "streamer died\n";
            }
            if ($path eq '/inner-eval-drop') {
                $w->write('aaa-');
                eval { die "caught inner\n" };
                $w->write('bbb');
                return;   # implicit drop must still seal CLEAN
            }
            if ($path eq '/inner-eval-close') {
                $w->write('ccc-');
                eval { die "caught inner\n" };
                $w->write('ddd');
                $w->close;
                return;
            }
            if ($path eq '/close-then-die') {
                $w->write('eee-');
                $w->write('fff');
                $w->close;
                die "died after close\n";
            }
            $w->write('fallthrough');
            $w->close;
        };
    });

    my $n = Feersum->new_instance();
    $n->use_socket($nsock);
    $n->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        $w->write('native1-');
        die "native died\n";
    });

    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $_ for $psock, $tsock, $nsock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

# Raw HTTP/1.1 exchange; returns the full byte stream up to EOF.
sub raw_get {
    my ($port, $path) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TIMEOUT_MULT) or return;
    print {$s} "GET $path HTTP/1.1\015\012Host: l\015\012"
             . "Connection: close\015\012\015\012";
    my $buf = q{};
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10 * TIMEOUT_MULT;
        while (1) {
            my $n = sysread $s, my $c, 65536;
            last if !$n;
            $buf .= $c;
        }
        alarm 0;
    };
    alarm 0;
    close $s;
    return $buf;
}

my $TERM = qr/\015\012 0 \015\012 \015\012 \z/x;   # chunked terminator at EOF

# 1. PSGI streamer dies mid-stream: partial body, NO terminating chunk.
{
    my $resp = raw_get($pport, '/die-after-write');
    like   $resp, qr/part1-/, 'dying streamer: the written chunk arrived';
    unlike $resp, $TERM,
        'dying streamer: response is NOT sealed clean (no terminating chunk)';
    my $died = do {
        local $/; open my $fh, '<', "$dir/died.log"; $fh ? <$fh> : q{} };
    like $died, qr/streamer died/, 'Feersum::DIED still fired for the die';
}

# 2. Native handler dies mid-stream: same dirty seal.
{
    my $resp = raw_get($nport, '/');
    unlike $resp, $TERM, 'dying native handler: no terminating chunk either';
}

# 3. Guards: perfectly good responses must stay complete and clean.
{
    my $resp = raw_get($pport, '/inner-eval-drop');
    ok $resp =~ /aaa-/ && $resp =~ /bbb/ && $resp =~ $TERM,
        'stale $@ from caught eval + implicit drop still seals clean'
        or diag $resp;
    $resp = raw_get($pport, '/inner-eval-close');
    ok $resp =~ /ccc-/ && $resp =~ /ddd/ && $resp =~ $TERM,
        'stale $@ from caught eval + explicit close still seals clean'
        or diag $resp;
    $resp = raw_get($pport, '/close-then-die');
    ok $resp =~ /eee-/ && $resp =~ /fff/ && $resp =~ $TERM,
        'close() before the die keeps the completed response intact'
        or diag $resp;
}

# 4. TLS: curl must SEE the truncation (nonzero exit; rc 18 is "transfer
# closed with outstanding read data remaining").  Pre-fix it got a clean
# rc 0 with a complete-looking chunked body.
SKIP: {
    skip 'TLS or curl not available', 2 unless $tls_ok;
    my $max = 15 * TIMEOUT_MULT;
    my $out = `curl -sS -k --http1.1 --max-time $max 'https://127.0.0.1:$tport/die-after-write' 2>/dev/null`;
    my $rc = $? >> 8;
    like $out, qr/part1-/, 'TLS dying streamer: partial body arrived';
    isnt $rc, 0, "TLS dying streamer: curl reports the truncation (rc=$rc)";
}

# 5. H2: the stream must end in RST_STREAM, not a clean END_STREAM.
SKIP: {
    skip 'H2 or nghttp not available', 1 unless $h2_ok;
    my $max = 15 * TIMEOUT_MULT;
    my $out = run_capped($max,
        ['nghttp', '--no-verify', '-v', "https://127.0.0.1:$tport/die-after-write"],
        merge_stderr => 1);
    like $out, qr/RST_STREAM/,
        'H2 dying streamer: client receives RST_STREAM, not END_STREAM';
}

reap_server($server);
