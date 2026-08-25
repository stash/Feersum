#!perl
# Request bodies over TLS: chunked Transfer-Encoding and Content-Length.
# Regression guard for the TLS post-handshake drain path, which must hand
# chunked body data to the chunked parser (not just the Content-Length path)
# when the body arrives in the same TCP segment as the TLS handshake.
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
        unless -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';
    plan tests => 2;
}

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';

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
$f->set_tls(cert_file => $cert, key_file => $key);

# Echo the decoded request body length and content so the client can verify
# the body was received intact regardless of transfer encoding.
$f->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    if (my $cl = $env->{CONTENT_LENGTH}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'],
        \("got=" . length($body) . ":$body"));
});

# Send a request over TLS, return the response body.
sub tls_request {
    my ($port, $request) = @_;
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => "127.0.0.1:$port",
        SSL_verify_mode => 0,
        Timeout         => 3 * TIMEOUT_MULT,
    ) or return undef;
    # Write headers+body in one go to give the post-handshake coalesced path
    # a chance to fire (and exercise the steady-state path otherwise).
    print $cl $request;
    local $/;
    my $resp = <$cl>;
    close $cl;
    return $resp;
}

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    EV::default_loop()->loop_fork;
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break });
    EV::run;
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/30b watchdog timeout\n" };
alarm 90 * TIMEOUT_MULT;

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

# Chunked body: "hello" + " world" = "hello world" (11 bytes decoded)
my $chunked = tls_request($port,
    "POST / HTTP/1.1\r\nHost: localhost\r\n"
    . "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    . "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n");
like $chunked // '', qr/got=11:hello world/,
    'chunked request body decoded correctly over TLS';

# Content-Length body
my $clbody = tls_request($port,
    "POST / HTTP/1.1\r\nHost: localhost\r\n"
    . "Content-Length: 9\r\nConnection: close\r\n\r\n"
    . "123456789");
like $clbody // '', qr/got=9:123456789/,
    'Content-Length request body read correctly over TLS';

alarm 0;
reap_server($pid);
