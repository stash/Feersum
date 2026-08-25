#!perl
# UTF8-flagged response strings are written as bytes: "caf\xE9" reaches the wire
# as \xE9 (as on other PSGI servers), and characters above 255 go out as UTF-8
# with self-consistent framing while the connection survives (the /wide legs).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new();
my $h2_ok = $probe->has_tls() && $probe->has_h2()
         && -f 't/certs/alpha.crt' && -f 't/certs/alpha.key'
         && do { my $p = `which nghttp 2>/dev/null`; chomp $p; -x ($p || '') };

plan tests => 15;

my $app = sub {
    my $env = shift;
    my $path = $env->{PATH_INFO} || '/';
    if ($path eq '/array') {
        my $s = "caf\xE9\n"; utf8::upgrade($s);
        return [200, ['Content-Type' => 'application/octet-stream'], [$s]];
    }
    if ($path eq '/stream') {
        my $s = "caf\xE9\n"; utf8::upgrade($s);
        return sub {
            my $w = $_[0]->([200, ['Content-Type' => 'application/octet-stream']]);
            $w->write($s);
            $w->close;
        };
    }
    if ($path eq '/hdr') {
        my $h = "caf\xE9"; utf8::upgrade($h);
        return [200, ['Content-Type' => 'text/plain', 'X-U' => $h], ['ok']];
    }
    if ($path eq '/wide') {
        return [200, ['Content-Type' => 'application/octet-stream'],
                ["snow\x{263A}\n"]];
    }
    return [200, ['Content-Type' => 'text/plain'], ['alive']];
};

sub spawn_server {
    my ($sock, @tls) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    return $pid if $pid;
    open STDOUT, '>', '/dev/null';
    open STDERR, '>&', \*STDOUT;
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->set_tls(@tls) if @tls;
    $f->psgi_request_handler($app);
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";
my $server = spawn_server($sock);
close $sock;

my ($h2sock, $h2port, $h2server);
if ($h2_ok) {
    ($h2sock, $h2port) = get_listen_socket();
    $h2server = spawn_server($h2sock, h2 => 1, cert_file => 't/certs/alpha.crt',
                             key_file => 't/certs/alpha.key');
    close $h2sock;
}
select undef, undef, undef, 1 * TIMEOUT_MULT;

# Returns { status, cl, xu, body, chunks => [sizes] } with chunked bodies
# reassembled, so both framings expose the payload bytes and their lengths.
sub fetch {
    my ($path, $method) = @_;
    $method ||= 'GET';
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 10 * TIMEOUT_MULT) or return {};
    syswrite $s, "$method $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    my $raw = '';
    eval { local $SIG{ALRM} = sub { die "to\n" }; alarm 10 * TIMEOUT_MULT;
           while (sysread($s, my $c, 65536)) { $raw .= $c } alarm 0; 1 };
    alarm 0; close $s;
    my ($head, $body) = split /\r\n\r\n/, $raw, 2;
    $body = '' unless defined $body;
    my %r;
    ($r{status}) = ($head // '') =~ m{^HTTP/1\.\d\s+(\d+)};
    $r{cl} = $1 if ($head // '') =~ /^Content-Length:\s*(\d+)/im;
    $r{xu} = $1 if ($head // '') =~ /^X-U:\s*([^\r\n]*)/im;
    if (($head // '') =~ /^Transfer-Encoding:\s*chunked/im) {
        my $out = '';
        while ($body =~ s/^([0-9a-fA-F]+)\r\n//) {
            my $n = hex $1;
            push @{$r{chunks}}, $n;
            last if $n == 0;
            $out .= substr($body, 0, $n, '');
            $body =~ s/^\r\n//;
        }
        $body = $out;
    }
    $r{body} = $body;
    return \%r;
}

# Arrayref body: the downgraded byte, and a Content-Length that matches it.
my $r = fetch('/array');
is unpack('H*', $r->{body}), '636166e90a',
   'arrayref body ships downgraded bytes';
is $r->{cl}, 5, 'Content-Length counts the downgraded bytes';

# Streaming writer: chunk payload and chunk size both see the downgraded form.
$r = fetch('/stream');
is unpack('H*', $r->{body}), '636166e90a',
   'streaming writer ships downgraded bytes';
is $r->{chunks} && $r->{chunks}[0], 5, 'chunk size is the downgraded length';

# Header value.
$r = fetch('/hdr');
is unpack('H*', $r->{xu} // ''), '636166e9',
   'header value ships downgraded bytes';

# HEAD advertises the length the equivalent GET would send.
$r = fetch('/array', 'HEAD');
is $r->{cl}, 5, 'HEAD Content-Length is the downgraded length';
is $r->{body}, '', 'HEAD carries no body';

# Wide characters (> 255, spec-illegal): UTF-8 bytes with consistent framing,
# and the server survives to answer the next request.
$r = fetch('/wide');
is unpack('H*', $r->{body}), '736e6f77e298ba0a',
   'wide chars keep their UTF-8 bytes (graceful degradation)';
is $r->{cl}, 8, 'wide-char Content-Length matches the bytes sent';
$r = fetch('/alive');
is $r->{body}, 'alive', 'connection framing survived the wide-char response';

# The native interface shares the same buffers.
{
    my ($nsock, $nport) = get_listen_socket();
    my $nsrv = fork();
    die "fork: $!" unless defined $nsrv;
    if (!$nsrv) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>&', \*STDOUT;
        my $f = Feersum->new_instance();
        $f->use_socket($nsock);
        $f->request_handler(sub {
            my $s = "caf\xE9\n"; utf8::upgrade($s);
            $_[0]->send_response(200, ['Content-Type' => 'text/plain'], $s);
        });
        my $t = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $nsock;
    select undef, undef, undef, 1 * TIMEOUT_MULT;
    my $raw = '';
    if (my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$nport",
                                      Timeout => 10 * TIMEOUT_MULT)) {
        syswrite $s, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        eval { local $SIG{ALRM} = sub { die "to\n" }; alarm 10 * TIMEOUT_MULT;
               while (sysread($s, my $c, 4096)) { $raw .= $c } alarm 0; 1 };
        alarm 0; close $s;
    }
    my ($b) = $raw =~ /\r\n\r\n(.*)$/s;
    is unpack('H*', $b // ''), '636166e90a',
       'native send_response ships downgraded bytes';
    my ($ncl) = $raw =~ /^Content-Length:\s*(\d+)/im;
    is $ncl, 5, 'native Content-Length counts the downgraded bytes';
    reap_server($nsrv);
}

# H2 must send the same bytes H1 does, in body and header value alike.
SKIP: {
    skip 'no TLS+H2+nghttp', 2 unless $h2_ok;
    my $got = `nghttp --no-verify-peer https://127.0.0.1:$h2port/array 2>/dev/null`;
    is unpack('H*', $got // ''), '636166e90a', 'H2 body matches H1 bytes';
    my $verbose = `nghttp -v --no-verify-peer https://127.0.0.1:$h2port/hdr 2>/dev/null`;
    my ($xu) = ($verbose // '') =~ /x-u:\s([^\r\n]*)/;
    is unpack('H*', $xu // ''), '636166e9', 'H2 header value matches H1 bytes';
}

reap_server($server);
reap_server($h2server) if $h2server;
