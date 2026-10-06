#!perl
# SNI matching must treat the trailing-dot FQDN form as the same name:
# a client sending 'beta.local.' gets the beta.local certificate.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    eval { require IO::Socket::SSL; 1 }
        or plan skip_all => "IO::Socket::SSL not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 't/certs/alpha.crt' && -f 't/certs/alpha.key'
            && -f 't/certs/beta.crt'  && -f 't/certs/beta.key';
    plan tests => 3;
}

use IO::Socket::INET;
use Socket qw(SOMAXCONN);

my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "listen: $!";
my $port = $sock->sockport;

my $f = Feersum->endjinn;
$f->use_socket($sock);
$f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key');
$f->set_tls(sni => 'beta.local', cert_file => 't/certs/beta.crt', key_file => 't/certs/beta.key');
$f->request_handler(sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"ok\n");
});

sub get_cert_cn {
    my ($hostname) = @_;
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => "127.0.0.1:$port",
        SSL_hostname    => $hostname,
        SSL_verify_mode => 0,
        Timeout         => 3 * TIMEOUT_MULT,
    ) or return undef;
    my $cn = $cl->peer_certificate('cn');
    close $cl;
    return $cn;
}

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    $SIG{QUIT} = 'DEFAULT';
    EV::default_loop()->loop_fork;
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break });
    EV::run;
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "watchdog timeout\n" };
alarm 90 * TIMEOUT_MULT;

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

is get_cert_cn('beta.local'), 'beta.local', 'plain SNI still matches';
# LibreSSL refuses to send a trailing-dot SNI name, so the client cannot exercise it
my $dot_sni = eval {
    my $ctx = Net::SSLeay::CTX_new() or die;
    my $ssl = Net::SSLeay::new($ctx) or die;
    my $ok = Net::SSLeay::set_tlsext_host_name($ssl, 'beta.local.');
    Net::SSLeay::free($ssl);
    Net::SSLeay::CTX_free($ctx);
    $ok;
};
SKIP: {
    skip 'TLS client library will not send a trailing-dot SNI name', 1 unless $dot_sni;
    is get_cert_cn('beta.local.'), 'beta.local', 'trailing-dot SNI matches too';
}
is get_cert_cn('unknown.local'), 'alpha.local', 'unknown SNI still gets the default';

alarm 0;
reap_server($pid);
