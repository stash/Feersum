#!perl
# max_read_buf bounds the header block on TLS as on plain: a header block that
# arrives complete inside one decrypt burst is still measured and answered 431.
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
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 6;

my $CAP = 4096;

sub spawn {
    my ($tls) = @_;
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
        $f->max_read_buf($CAP);
        $f->read_timeout(15 * TIMEOUT_MULT);
        $f->header_timeout(15 * TIMEOUT_MULT);
        eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key,
                           h2 => 0) } if $tls;
        $f->psgi_request_handler(sub {
            [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
        });
        my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $lsock;
    return ($pid, $lport);
}

# One write, so an oversized block can arrive in a single decrypt burst.
sub status_for {
    my ($port, $tls, $size) = @_;
    my $s = $tls
        ? IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", SSL_verify_mode => 0,
              SSL_alpn_protocols => ['http/1.1'], Timeout => 10 * TIMEOUT_MULT)
        : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
              Timeout => 10 * TIMEOUT_MULT);
    return '(no connection)' unless $s;
    print {$s} "GET /ok HTTP/1.1\r\nHost: x\r\nX-Big: " . ('A' x $size)
             . "\r\nConnection: close\r\n\r\n";
    my $raw = '';
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 15 * TIMEOUT_MULT;
        while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $raw .= $z }
        alarm 0;
        1;
    };
    alarm 0;
    close $s;
    return $raw =~ m{\AHTTP/1\.\d (\d{3})} ? $1 : '(none)';
}

for my $tls (0, 1) {
    my $name = $tls ? 'TLS' : 'plain';
    my ($pid, $port) = spawn($tls);
    select undef, undef, undef, 1 * TIMEOUT_MULT;
    is status_for($port, $tls, 100),   '200',
        "$name: a small header block is served";
    is status_for($port, $tls, $CAP + 4), '431',
        "$name: a header block just over max_read_buf is refused";
    is status_for($port, $tls, 30000), '431',
        "$name: a header block 7x over max_read_buf is refused";
    reap_server($pid);
}
