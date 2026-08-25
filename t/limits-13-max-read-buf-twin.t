#!perl
# max_read_buf bounds the header block and chunked reception, not a declared
# Content-Length body (that is max_body_len); plain and TLS must agree under
# one setting, both on a small limit and on a body inside one decrypt burst.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Socket qw(SOMAXCONN);

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';

my $tls_ok;
BEGIN {
    require Feersum;
    $tls_ok = Feersum->endjinn->has_tls()
           && (eval { require IO::Socket::SSL; require Net::SSLeay; 1 } || 0)
           && tls_client_ok()
           && -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';
    plan tests => 8;
}

use constant MRB => 8192;

sub spawn {
    my ($tls) = @_;
    my ($lsn, $port) = get_listen_socket();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        # A bare Feersum child can inherit SIG_IGN for QUIT (make test on
        # alpine does this), making the kill below a no-op.
        $SIG{QUIT} = q{DEFAULT};
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        my $f = Feersum->new_instance();
        $f->use_socket($lsn);
        $f->set_tls(cert_file => $cert, key_file => $key) if $tls;
        $f->max_read_buf(MRB);
        $f->read_timeout(10 * TIMEOUT_MULT);
        $f->request_handler(sub {
            $_[0]->send_response("200 OK", ['Content-Length' => 2], "OK");
        });
        EV::run();
        POSIX::_exit(0);
    }
    close $lsn;
    return ($pid, $port);
}

my ($ppid, $pport) = spawn(0);
my ($tpid, $tport) = $tls_ok ? spawn(1) : ();
select undef, undef, undef, 1 * TIMEOUT_MULT;

sub status {
    my ($tls, $req) = @_;
    my $s = $tls
        ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $tport,
              SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
              SSL_alpn_protocols => ['http/1.1'], Timeout => 5 * TIMEOUT_MULT)
        : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $pport,
              Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT);
    return 'CONNFAIL' unless $s;
    print $s $req;
    my $raw = '';
    eval { local $SIG{ALRM} = sub { die "to\n" }; alarm 8 * TIMEOUT_MULT;
           while (sysread($s, my $c, 4096)) {
               $raw .= $c; last if $raw =~ /\r\n\r\n/;
           }
           alarm 0; 1 } or alarm 0;
    close $s;
    my ($code) = $raw =~ m{^HTTP/1\.[01] (\d\d\d)};
    return $code || 'NORESP';
}

sub body_req {
    my ($n) = @_;
    return "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: $n\r\n"
         . "Connection: close\r\n\r\n" . ('x' x $n);
}
sub header_req {
    my ($n) = @_;
    return "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: " . ('p' x $n)
         . "\r\nConnection: close\r\n\r\n";
}

# name => [request, expected status]
my @CASES = (
    ['a declared-CL body far above max_read_buf' => body_req(20000),   '200'],
    ['a small header block'                      => header_req(3000),  '200'],
    ['a header block just under max_read_buf'    => header_req(7000),  '200'],
    ['a header block far above max_read_buf'     => header_req(30000), '431'],
);

for my $c (@CASES) {
    my ($name, $req, $want) = @$c;
    is status(0, $req), $want, "plain: $name -> $want";
}

SKIP: {
    skip 'no TLS client available', 4 unless $tls_ok;
    for my $c (@CASES) {
        my ($name, $req, $want) = @$c;
        is status(1, $req), $want, "TLS twin: $name -> $want";
    }
}

kill 'QUIT', grep { defined } $ppid, $tpid;
waitpid($_, 0) for grep { defined } $ppid, $tpid;
