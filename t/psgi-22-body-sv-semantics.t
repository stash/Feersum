#!perl
# An app scalar reaches the wire as its bytes: a magic lvalue such as
# substr($buf, 4) passed to write()/send_response() is fetched rather than read
# as undef, and an H2 array body goes out element by element with the same
# bytes as H1, never as a character-semantics concatenation.
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

# Eight H1 tests always, plus two H2 ones that skip (and so still report) when
# TLS/H2/nghttp are missing.  The H1 legs use a plain listener: nothing here is
# about transport, and `openssl s_client` is unreliable where it is LibreSSL.
plan tests => 10;

my $BUF = 'data-payload';

my $app = sub {
    my $env = shift;
    my ($k) = ($env->{PATH_INFO} // '') =~ m{^/(.+)};
    $k //= '';
    # Array bodies (also the H2 leg).
    if ($k eq 'mixed') {
        my $u = chr(0xE9); utf8::upgrade($u);
        return [200, ['Content-Type' => 'application/octet-stream'],
                [$u, chr(0xFF)]];
    }
    if ($k eq 'bytes') {
        return [200, ['Content-Type' => 'application/octet-stream'],
                ["ab", "cd"]];
    }
    # Streaming writer takes magic lvalues directly.
    return sub {
        my $w = $_[0]->([200, ['Content-Type' => 'text/plain']]);
        $w->write(substr($BUF, 4))    if $k eq 'w-substr2';
        $w->write(substr($BUF, 0, 4)) if $k eq 'w-substr3';
        if ($k eq 'w-dollar1') { "match-me" =~ /(match)/; $w->write($1) }
        if ($k eq 'w-lexical') { my $x = substr($BUF, 4); $w->write($x) }
        $w->close;
    };
};

# $tls is a pair of set_tls args, or nothing for a plain listener.
sub spawn_server {
    my ($sock, @tls) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    return $pid if $pid;
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
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

# The H2 leg needs its own TLS listener; the H1 legs above stay plain.
my ($h2sock, $h2port, $h2server);
if ($h2_ok) {
    ($h2sock, $h2port) = get_listen_socket();
    $h2server = spawn_server($h2sock, h2 => 1, cert_file => 't/certs/alpha.crt',
                             key_file => 't/certs/alpha.key');
    close $h2sock;
}
select undef, undef, undef, 1 * TIMEOUT_MULT;

sub body_of {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 10 * TIMEOUT_MULT) or return '';
    syswrite $s, "GET /$path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    my $raw = '';
    eval { local $SIG{ALRM} = sub { die "to\n" }; alarm 10 * TIMEOUT_MULT;
           while (sysread($s, my $c, 4096)) { $raw .= $c } alarm 0; 1 };
    alarm 0; close $s;
    my ($b) = $raw =~ /\r\n\r\n(.*)$/s;
    return $b // '';
}

# Chunked framing: strip the chunk sizes to get the payload.
sub dechunk {
    my ($b) = @_;
    my $out = '';
    while ($b =~ s/^([0-9a-fA-F]+)\r\n//) {
        my $n = hex $1;
        last if $n == 0;
        $out .= substr($b, 0, $n, '');
        $b =~ s/^\r\n//;
    }
    return $out;
}

is dechunk(body_of('w-substr2')), '-payload',
   'write(substr($buf,4)) delivers its bytes';
is dechunk(body_of('w-substr3')), 'data',
   'write(substr($buf,0,4)) delivers its bytes';
is dechunk(body_of('w-dollar1')), 'match',
   'write($1) delivers its bytes';
is dechunk(body_of('w-lexical')), '-payload',
   'the same value via a lexical is unchanged';

# The native interface has its own copy of the same guard.
{
    my ($nsock, $nport) = get_listen_socket();
    my $nsrv = fork();
    die "fork: $!" unless defined $nsrv;
    if (!$nsrv) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        my $f = Feersum->new_instance();
        $f->use_socket($nsock);
        $f->request_handler(sub {
            $_[0]->send_response(200, ['Content-Type' => 'text/plain'],
                                 substr($BUF, 4));
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
    is $b // '', '-payload',
       'send_response(substr(...)) delivers its bytes';
    reap_server($nsrv);
}

# H1 array bodies are byte concatenation, whatever flags the elements carry;
# the flagged \xE9 element ships downgraded, the plain \xFF untouched.
is unpack('H*', body_of('mixed')), 'e9ff',
   'H1 array body is the elements\' bytes, not a character concatenation';

# The H1 twin needs no H2, so it stays outside the SKIP block.
is unpack('H*', body_of('bytes')), '61626364',
   'H1 twin of the plain array body';

SKIP: {
    skip 'no TLS+H2+nghttp', 2 unless $h2_ok;
    for my $case (['mixed', 'e9ff'], ['bytes', '61626364']) {
        my $got = `nghttp --no-verify-peer https://127.0.0.1:$h2port/$case->[0] 2>/dev/null`;
        is unpack('H*', $got // ''), $case->[1],
           "H2 array body '$case->[0]' is the same bytes H1 sends";
    }
}

reap_server($server);
reap_server($h2server) if $h2server;
