#!perl
# psgi.input getline follows readline semantics for $/ (line, plain separator,
# \N records, "" paragraph mode, undef slurp), returns undef at end of input,
# never crosses into a pipelined request, <$fh> serves both contexts, and the
# handle converts like a plain ref.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use Feersum;
use Scalar::Util ();

plan tests => 15;

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

# Copied verbatim from Plack::App::WrapCGI::slurp_fh
sub slurp_fh {
    my $fh = $_[0];
    local $/;
    my $v = <$fh>;
    defined $v ? $v : '';
}

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->set_keepalive(1);    # the pipeline case needs it
    $f->read_timeout(15 * TIMEOUT_MULT);
    $f->header_timeout(15 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $p  = $env->{PATH_INFO} || q{};
        my $in = $env->{'psgi.input'};
        my $out;
        if ($p eq '/lines') {
            my @l;
            while (defined(my $x = $in->getline)) { push @l, $x }
            my $eof = defined $in->getline ? 'DEF' : 'undef';
            my $sc = 'nocroak';
            eval { my $n = $in->getlines; 1 } or $sc = 'croaked';
            $out = 'j=[' . join('|', @l) . "] eof=$eof sc=$sc";
        }
        elsif ($p eq '/slurp') {
            my $s1 = slurp_fh($in);
            my $s2 = slurp_fh($in);
            $out = "s1=[$s1] s2=[$s2]";
        }
        elsif ($p eq '/list') {
            my @all = <$in>;
            $out = 'n=' . scalar(@all) . ' j=[' . join('|', @all) . ']';
        }
        elsif ($p eq '/sep') {
            local $/ = 'XX';
            my @l;
            while (defined(my $x = $in->getline)) { push @l, $x }
            $out = 'j=[' . join('|', @l) . ']';
        }
        elsif ($p eq '/record') {
            local $/ = \3;
            my @l;
            while (defined(my $x = $in->getline)) { push @l, $x }
            $out = 'j=[' . join('|', @l) . ']';
        }
        elsif ($p eq '/para') {
            local $/ = q{};
            my @l;
            while (defined(my $x = $in->getline)) { push @l, $x }
            $out = 'j=[' . join('|', @l) . ']';
        }
        elsif ($p eq '/mixed') {
            my $g = $in->getline;
            my $rest = q{};
            $in->read($rest, 999);
            $out = "g=[$g] rest=[$rest]";
        }
        elsif ($p eq '/empty') {
            my $eof = eval { defined $in->getline ? 'DEF' : 'undef' };
            $eof = 'CROAK' unless defined $eof;
            my $err = $@ || q{};
            $out = "eof=$eof err=[$err]";
        }
        elsif ($p eq '/writer') {
            return sub {
                my $w = $_[0]->([200, ['Content-Type' => 'text/plain']]);
                my ($e1, $e2) = ('none', 'none');
                eval { $w->getline; 1 } or $e1 = $@;
                eval { my @x = $w->getlines; 1 } or $e2 = $@;
                my $o = "wg=[$e1] wgs=[$e2]";
                $o =~ s/\n/\\n/g;
                $w->write($o);
                $w->close;
            };
        }
        elsif ($p eq '/conv') {
            my $truth = $in ? 1 : 0;
            my $num = Scalar::Util::refaddr($in) == 0 + $in ? 'addr' : 'other';
            $out = "str=[$in] num=$num bool=$truth g=[" . $in->getline . ']';
        }
        elsif ($p eq '/pipe') {
            my $g1 = $in->getline;
            my $g2 = $in->getline;
            my $g3 = defined $in->getline ? 'DEF' : 'undef';
            $out = 'g1=[' . (defined $g1 ? $g1 : 'undef')
                 . '] g2=[' . (defined $g2 ? $g2 : 'undef') . "] g3=$g3";
        }
        else {
            $out = 'after-ok';
        }
        $out =~ s/\n/\\n/g;
        return [200, ['Content-Type' => 'text/plain'], [$out]];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

sub req {
    my ($method, $path, $body) = @_;
    $body = q{} unless defined $body;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 8 * TIMEOUT_MULT) or return 'CONNFAIL';
    syswrite $s, "$method $path HTTP/1.1\r\nHost: x\r\n"
        . 'Content-Length: ' . length($body) . "\r\nConnection: close\r\n\r\n$body";
    my ($buf, $g) = (q{});
    while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
    close $s;
    my ($got) = $buf =~ /\r\n\r\n(.*)\z/s;
    return defined $got ? $got : 'NO-BODY';
}

is req(POST => '/lines', "one\ntwo\nnoeol"),
    'j=[one\\n|two\\n|noeol] eof=undef sc=croaked',
    'getline honours default $/, undef at EOF, getlines croaks in scalar context';

is req(POST => '/slurp', "a\nb\nc"), 's1=[a\\nb\\nc] s2=[]',
    'WrapCGI-style slurp (local $/; <$fh>) gets the whole body, then EOF';

SKIP: {
    # Before 5.18 an overloaded <> is not handed the caller's list context, so
    # the handler sees wantarray false and yields one record.  Scalar context -
    # including the slurp above, which is what shipped code uses - is fine.
    skip 'overloaded <> gets no list context before perl 5.18', 1 if $] < 5.018;
    is req(POST => '/list', "x\ny\nz"), 'n=3 j=[x\\n|y\\n|z]',
        'list-context <$fh> returns all lines';
}

is req(POST => '/sep', 'aXXbXXc'), 'j=[aXX|bXX|c]',
    'plain-string $/ separator';

is req(POST => '/record', 'abcdefg'), 'j=[abc|def|g]',
    '$/ = \\N record mode, short final record';

is req(POST => '/para', "\npA1\npA2\n\n\npB tail"),
    'j=[pA1\\npA2\\n\\n|pB tail]',
    '$/ = "" paragraph mode skips leading and eats trailing newline runs';

is req(POST => '/mixed', "hdr\nrest of the body"),
    'g=[hdr\\n] rest=[rest of the body]',
    'getline and read() share one position';

like req(POST => '/conv', "first\nsecond"),
    qr/^str=\[Feersum::Connection::Reader=\w+\(0x[0-9a-f]+\)\] num=addr bool=1 g=\[first\\n\]\z/,
    'psgi.input stringifies and numifies like a plain ref; a bool test reads nothing';

is req(GET => '/empty'), 'eof=undef err=[]',
    'getline on a bodyless request is immediate EOF';

my $w = req(POST => '/writer', 'ignored');
like $w, qr/wg=\[can't call getline\(\) on a write-only handle/,
    'getline croaks on the writer';
like $w, qr/wgs=\[can't call getlines\(\) on a write-only handle/,
    'getlines croaks on the writer';

# A 5-byte body with the next request pipelined in the same segment: getline
# must stop at the body boundary, not serve the second request's bytes.
{
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 8 * TIMEOUT_MULT);
    ok $s, 'pipeline socket connected';
    syswrite $s, "POST /pipe HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nAB\nCD"
        . "GET /after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    my ($buf, $g) = (q{});
    while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
    close $s;
    like $buf, qr/g1=\[AB\\n\] g2=\[CD\] g3=undef/,
        'getline stops at the body boundary';
    like $buf, qr/after-ok/, 'the pipelined next request survives intact';
}

reap_server($server);
