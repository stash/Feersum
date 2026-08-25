#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use IO::Socket::INET;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

# Create two listen sockets on different ports
my ($socket1, $port1) = get_listen_socket();
ok $socket1, "got plain listen socket on port $port1";

my ($socket2, $port2) = get_listen_socket();
ok $socket2, "got TLS listen socket on port $port2";

# Add both sockets - listener 0 is plain, listener 1 is TLS
$evh->use_socket($socket1);
$evh->use_socket($socket2);

# Enable TLS only on listener 1 (the second socket)
eval { $evh->set_tls(listener => 1, cert_file => $cert_file, key_file => $key_file) };
is $@, '', "set_tls on listener 1 only";

my @received_requests;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    my $path   = $env->{PATH_INFO} || '/';
    my $scheme = $env->{'psgi.url_scheme'} || 'http';
    push @received_requests, { path => $path, scheme => $scheme };

    my $body = "path=$path scheme=$scheme";
    $r->send_response("200 OK", [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($body),
        'Connection'     => 'close',
    ], $body);
});

my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

    # 1. Plain HTTP to port1 (listener 0, no TLS)
    my $plain = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port1",
        Proto    => 'tcp',
        Timeout  => 5 * TIMEOUT_MULT,
    );
    unless ($plain) {
        warn "Plain connect failed: $!\n";
        exit(1);
    }

    print $plain "GET /plain HTTP/1.1\r\nHost: localhost:$port1\r\nConnection: close\r\n\r\n";

    my $resp1 = '';
    while (defined(my $line = <$plain>)) {
        $resp1 .= $line;
    }
    close $plain;

    unless ($resp1 =~ /200 OK/ && $resp1 =~ /scheme=http/) {
        warn "Plain response bad: $resp1\n";
        exit(2);
    }

    # 2. TLS to port2 (listener 1, with TLS)
    my $tls = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port2,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 5 * TIMEOUT_MULT,
    );
    unless ($tls) {
        warn "TLS connect failed: " . IO::Socket::SSL::errstr() . "\n";
        exit(3);
    }

    $tls->print("GET /secure HTTP/1.1\r\nHost: localhost:$port2\r\nConnection: close\r\n\r\n");

    my $resp2 = '';
    while (defined(my $line = $tls->getline())) {
        $resp2 .= $line;
    }
    $tls->close(SSL_no_shutdown => 1);

    unless ($resp2 =~ /200 OK/ && $resp2 =~ /scheme=https/) {
        warn "TLS response bad: $resp2\n";
        exit(4);
    }

    exit(0);
}

# Parent: run event loop
my $cv = AE::cv;
my $child_status;
my $timeout = AE::timer(15 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for mixed listener client";
    $cv->send('timeout');
});
my $child_w = AE::child($pid, sub {
    my ($pid, $status) = @_;
    $child_status = $status >> 8;
    $cv->send('child_done');
});

my $reason = $cv->recv;
isnt $reason, 'timeout', "mixed listener test did not timeout";
is $child_status, 0, "mixed plain/TLS client got both responses";

cmp_ok scalar(@received_requests), '==', 2,
    "server received 2 requests (one per listener)";

if (@received_requests >= 2) {
    is $received_requests[0]{path}, '/plain', "plain request path correct";
    is $received_requests[0]{scheme}, 'http', "plain request scheme is http";
    is $received_requests[1]{path}, '/secure', "TLS request path correct";
    is $received_requests[1]{scheme}, 'https', "TLS request scheme is https";
}

done_testing;
