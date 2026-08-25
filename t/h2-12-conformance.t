#!perl
# H2 conformance: an app-declared Content-Length is normalised as on HTTP/1.1
# and dropped on 204, a HEAD response emits no DATA frames, and ALPN with no
# overlap is a fatal no_application_protocol alert rather than a fallback.
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

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert && -f $key;

chomp(my $nghttp = `which nghttp 2>/dev/null` || '');
plan skip_all => "nghttp not found in PATH" unless $nghttp && -x $nghttp;
chomp(my $openssl = `which openssl 2>/dev/null` || '');
plan skip_all => "openssl not found in PATH" unless $openssl && -x $openssl;

plan tests => 15;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
eval { $feer->set_tls(cert_file => $cert, key_file => $key, h2 => 1) };
is $@, '', "set_tls with h2";

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '/';
    if ($p eq q{/stream}) {
        return sub {
            my $respond = shift;
            my $w = $respond->([200, [q{Content-Type} => q{text/plain}]]);
            $main::WRITE_OK = eval { $w->write(q{STREAMED}); 1 } ? 1 : 0;
            $w->close;
        };
    }
    if ($p eq q{/streamcheck}) {
        my $b = ($main::WRITE_OK ? q{write_ok} : q{write_croaked});
        return [200, [q{Content-Length} => length $b], [$b]];
    }
    # The app lies: declares 100, returns 5 bytes.
    return [200, ['Content-Type'=>'text/plain', 'Content-Length'=>100], ['hello']]
        if $p eq '/badcl';
    # RFC 9110 8.6: a 204 must not carry Content-Length.
    return [204, ['Content-Length' => 12], []] if $p eq '/cl204';
    # 205 with an app Content-Length and no body
    return [205, [q{Content-Type}=>q{text/plain}, q{Content-Length}=>9], [q{nobody205}]]
        if $p eq q{/205cl};
    return [200, ['Content-Type'=>'text/plain'], ['hello']];
});

# Run $cmd in a child while the server's event loop pumps in the parent.
sub with_server {
    my ($label, $cmd) = @_;
    pipe(my $rd, my $wr) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        close $rd;
        select undef, undef, undef, 0.3 * TMULT;
        my $out = `$cmd`;
        print $wr $out;
        close $wr;
        exit 0;
    }
    close $wr;
    my $out = '';
    my $done = 0;
    my $io = EV::io($rd, EV::READ, sub {
        my $buf;
        my $n = sysread($rd, $buf, 65536);
        if (!$n) { $done = 1; EV::break(EV::BREAK_ALL()); return }
        $out .= $buf;
    });
    my $to = EV::timer(20 * TMULT, 0, sub { EV::break(EV::BREAK_ALL()) });
    EV::run;
    kill 'KILL', $pid;
    waitpid($pid, 0);
    close $rd;
    return $out;
}

#####################################################################
# 1. H2 must emit the real Content-Length, not the app's bogus one.
#####################################################################
{
    my $out = with_server("badcl",
        "$nghttp -v -n --no-verify 'https://127.0.0.1:$port/badcl' 2>/dev/null");
    like $out, qr/content-length:\s*5\b/,
        "H2 replaced the app's wrong Content-Length with the real length";
    unlike $out, qr/content-length:\s*100\b/,
        "H2 did not pass the app's bogus Content-Length through";
}

#####################################################################
# 2. A 204 must carry no Content-Length at all.
#####################################################################
{
    my $out = with_server("cl204",
        "$nghttp -v -n --no-verify 'https://127.0.0.1:$port/cl204' 2>/dev/null");
    like $out, qr/:status:\s*204/, "204 response received over H2";
    # Pre-fix the app's "Content-Length: 12" was copied through verbatim and
    # nghttp rejected it as an invalid field, then reset the stream.  Assert on
    # that rejection rather than on the bare header name: nghttp reports the
    # offender as "[content-length], value: [12]", which a plain
    # /content-length:/ match would miss entirely.
    unlike $out, qr/Invalid HTTP header field/i,
        "204 did not carry a Content-Length nghttp rejects";
    unlike $out, qr/RST_STREAM/,
        "204 did not cause the client to reset the stream";
}

#####################################################################
# 3. HEAD must produce no DATA frames.
#####################################################################
{
    my $out = with_server("head",
        "$nghttp -v -n -H':method: HEAD' --no-verify 'https://127.0.0.1:$port/' 2>/dev/null");
    # Positive assertion first, so the negative one below cannot pass merely
    # because the capture came back empty.
    like $out, qr/:status:\s*200/, "HEAD over H2 got a 200 response";
    unlike $out, qr/recv DATA frame/,
        "HEAD over H2 produced no DATA frame";
}

#####################################################################
# 4. ALPN with no overlap must fail the handshake, not fall back to H1.
#####################################################################
{
    my $out = with_server("alpn",
        "echo | $openssl s_client -connect 127.0.0.1:$port -alpn h3 2>&1");
    like $out, qr/no application protocol|alert number 120/i,
        "unsupported-only ALPN got a fatal no_application_protocol alert";
}

#####################################################################
# 5. A 205 over H2 must not carry the app's Content-Length: there are no DATA
#    frames, so the declared length cannot match the frame sum and nghttp2
#    rejects the response as malformed (RFC 9113 8.1.1).
#####################################################################
{
    my $out = with_server("205cl",
        "$nghttp -v -n --no-verify 'https://127.0.0.1:$port/205cl' 2>/dev/null");
    like $out, qr/:status:\s*205/, "205 response received over H2";
    unlike $out, qr/Invalid HTTP header field|error=Violation/i,
        "205 did not carry a Content-Length nghttp2 rejects";
}

#####################################################################
# 6. HEAD with a delayed/streaming PSGI response over H2: the stream is
#    completed at start_response, and the handler's later write() must not croak
#####################################################################
{
    my $out = with_server("head-streaming",
        "$nghttp -v -n -H':method: HEAD' --no-verify 'https://127.0.0.1:$port/stream' 2>/dev/null");
    like $out, qr/:status:\s*200/, "HEAD on a streaming H2 handler got 200";
    unlike $out, qr/recv DATA frame/, "HEAD on a streaming H2 handler sent no DATA";
    # The handler records whether its write() threw; /streamcheck reports it.
    my $chk = with_server("head-streaming-check",
        "$nghttp --no-verify 'https://127.0.0.1:$port/streamcheck' 2>/dev/null");
    like $chk, qr{\bwrite_ok\b},
        "the streaming handler write() did not croak on HEAD"
        or diag "streamcheck returned: [$chk]";
}
