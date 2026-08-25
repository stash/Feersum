#!perl
# A HEAD response carries no body (a keepalive client would read it as the
# next status line), and an unterminated chunk-size line is bounded in length
# and not re-scanned from its start on every read.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use Socket ();
use EV;

plan tests => 15;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
# Small cap so an over-long URI triggers a server-generated 414 below.
$feer->max_uri_len(128);

# Swallow the DIED noise from the dying-handler test below.
{ no warnings q{redefine}; *Feersum::DIED = sub { }; }

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '/';
    # Streaming response: exercises the chunked write path and its terminator,
    # which HEAD must suppress entirely.
    if ($p eq '/stream') {
        return sub {
            my $respond = shift;
            my $w = $respond->([200, ['Content-Type' => 'text/plain']]);
            $w->write("STREAMED-BODY");
            $w->close;
        };
    }
    die "deliberate handler death\n" if $p eq q{/dies};
    return [205, [q{Content-Type} => q{text/plain}], [q{nobody205}]] if $p eq q{/205};
    return [205, [q{Content-Type} => q{text/plain}, q{Content-Length} => 9], [q{nobody205}]] if $p eq q{/205cl};
    return [404, ['Content-Type' => 'text/plain'], ['nope']] if $p eq '/missing';
    # a >4KB body exercises the separate-iovec branch of the write fast path
    return [200, ['Content-Type' => 'text/plain'], ['B' x 5000]] if $p eq '/large';
    return [200, ['Content-Type' => 'text/plain'], ['BODY-FOR-200']];
});

#####################################################################
# 1. HEAD must send headers (incl. Content-Length) but no body, and must
#    not desynchronise a pipelined keepalive connection.
#####################################################################
{
    run_client("head-no-body", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # HEAD then GET in one write, on one keepalive connection.
        $s->print("HEAD / HTTP/1.1\015\012Host: l\015\012\015\012".
                  "GET /missing HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $all = '';
        while (my $l = <$s>) { $all .= $l }

        # Pre-fix the wire read "...\r\n\r\nBODY-FOR-200HTTP/1.1 404...".
        return 11 if $all =~ /BODY-FOR-200/;
        # HEAD response still advertises the length a GET would have sent.
        return 12 unless $all =~ m{^HTTP/1\.1 200 OK\b}m;
        return 13 unless $all =~ /Content-Length:\s*12\b/i;
        # The next response must start cleanly on its own line.
        return 14 unless $all =~ m{\015\012\015\012HTTP/1\.1 404 Not Found\b};
        return 15 unless $all =~ /nope/;
        return 0;
    });}

#####################################################################
# 1b. Same for a body over 4KB, which takes the other fast-path branch.
#####################################################################
{
    run_client("head-no-body-large", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("HEAD /large HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $all = '';
        while (my $l = <$s>) { $all .= $l }
        return 11 if $all =~ /BBBB/;                      # no body bytes
        return 12 unless $all =~ /Content-Length:\s*5000\b/i;
        return 0;
    });}

#####################################################################
# 1c. Server-generated error responses must obey HEAD too.  These are built
#     by respond_with_server_error(), which bypasses the normal body path.
#####################################################################
{
    run_client("head-no-body-error", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # Over-long URI -> 414 from the server itself, not from the handler.
        $s->print("HEAD /" . ('u' x 300) . " HTTP/1.1\015\012Host: l\015\012\015\012");
        my $all = '';
        while (my $l = <$s>) { $all .= $l }
        return 11 unless $all =~ m{^HTTP/1\.[01] 414\b};
        my ($cl) = $all =~ /Content-Length:\s*(\d+)/i;
        return 12 unless defined $cl && $cl > 0;   # length a GET would send
        my ($body) = $all =~ /\015\012\015\012(.*)/s;
        return 13 if length($body // '');          # ...but no body bytes
        return 0;
    });
}

#####################################################################
# 1d. Streaming responses must obey HEAD too - including the terminating
#     chunk, which a HEAD client would otherwise read as the next response.
#     The headers stay exactly as a GET would get them (RFC 9110 9.3.2).
#####################################################################
{
    run_client("head-no-body-streaming", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("HEAD /stream HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $all = '';
        while (my $l = <$s>) { $all .= $l }
        my ($hdr, $body) = split /\015\012\015\012/, $all, 2;
        return 11 unless $hdr =~ m{^HTTP/1\.1 200\b};
        # Same framing header a GET would have received...
        return 12 unless $hdr =~ /Transfer-Encoding:\s*chunked/i;
        # ...but not one byte of body, terminating chunk included.
        return 13 if length($body // '');
        return 0;
    });
    # Control: the same handler over GET still streams its chunked body.
    run_client("streaming-get-unaffected", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("GET /stream HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $all = '';
        while (my $l = <$s>) { $all .= $l }
        return 11 unless $all =~ /STREAMED-BODY/;
        return 12 unless $all =~ /\r\n0\r\n\r\n\z/;   # terminating chunk present
        return 0;
    });
}

#####################################################################
# 3. An unterminated chunk-size line must be rejected, not accepted forever.
#####################################################################
{
    run_client("chunk-size-line-bounded", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("POST / HTTP/1.1\015\012Host: l\015\012".
                  "Transfer-Encoding: chunked\015\012\015\012");
        $s->flush;
        # Leading zeros are legal hex and never overflow the size check, so
        # pre-fix this could grow without bound.
        my $sent = 0;
        for (1 .. 4000) {
            my $n = syswrite($s, '0') or last;
            $sent += $n;
        }
        my $resp = '';
        eval {
            local $SIG{ALRM} = sub { die "hang\n" };
            alarm(15 * TMULT);
            while (my $l = <$s>) { $resp .= $l; last if $resp =~ /\015\012\015\012/ }
            alarm(0);
        };
        alarm(0);
        return 11 if $@;
        return 12 unless $resp =~ m{^HTTP/1\.[01] 400\b};
        return 0;
    });}

# run_client() drives the event loop itself via $cv->recv, so there is no
# trailing EV::run here (see t/100 for the same pattern).

#####################################################################
# 4. 205 Reset Content carries a length delimiter: it is not in the RFC 9112
#    6.3 no-body list, so it needs Content-Length: 0, chunked, or a close
#####################################################################
{
    run_client("205-has-length-delimiter", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # /205 declares no length; /205cl declares a bogus 9 with no body.
        for my $path (qw(/205 /205cl)) {
            $s->print("GET $path HTTP/1.1\015\012Host: l\015\012\015\012");
        }
        $s->print("GET /missing HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $all = '';
        while (my $l = <$s>) { $all .= $l }
        my @cl = $all =~ /Content-Length:\s*(\d+)/gi;
        # both 205s must advertise 0, not nothing and not the app's 9
        return 11 unless ($cl[0] // -1) == 0;
        return 12 unless ($cl[1] // -1) == 0;
        return 13 if $all =~ /nobody205/;          # no body bytes on the wire
        return 14 unless $all =~ /nope/;           # the pipeline stayed in sync
        return 0;
    });
}

