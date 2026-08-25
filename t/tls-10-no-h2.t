#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

plan skip_all => "Feersum not compiled with H2 support"
    unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my $nghttp_bin = `which nghttp 2>/dev/null`;
chomp $nghttp_bin;
plan skip_all => "nghttp not found in PATH"
    unless $nghttp_bin && -x $nghttp_bin;

diag "using nghttp: $nghttp_bin";

# Set up two TLS listeners: one with H2, one without
my ($socket1, $port1) = get_listen_socket();
ok $socket1, "got H2-enabled TLS socket on port $port1";

my ($socket2, $port2) = get_listen_socket();
ok $socket2, "got H2-disabled TLS socket on port $port2";

$evh->use_socket($socket1);
$evh->use_socket($socket2);

# Listener 0: TLS with H2 (explicitly enabled)
eval { $evh->set_tls(listener => 0, cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls on listener 0 (h2 enabled)";

# Listener 1: TLS without H2 (default: off)
eval { $evh->set_tls(listener => 1, cert_file => $cert_file, key_file => $key_file) };
is $@, '', "set_tls on listener 1 (h2 off by default)";

my @received_requests;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    my $path   = $env->{PATH_INFO} || '/';
    my $scheme = $env->{'psgi.url_scheme'} || 'http';
    my $proto  = $env->{SERVER_PROTOCOL} || 'HTTP/1.0';
    push @received_requests, { path => $path, scheme => $scheme, proto => $proto };

    my $body = "path=$path scheme=$scheme proto=$proto";
    $r->send_response("200 OK", [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($body),
        'Connection'     => 'close',
    ], $body);
});

# ---------------------------------------------------------------------------
# Test 1: nghttp to H2-enabled listener should get HTTP/2
# ---------------------------------------------------------------------------
my $pid1 = fork();
die "fork failed: $!" unless defined $pid1;

if ($pid1 == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
    my $url = "https://127.0.0.1:$port1/h2-yes";
    my $output = `$nghttp_bin --no-verify -v $url 2>&1`;
    my $rc = $? >> 8;
    if ($rc == 0 && $output =~ /proto=HTTP\/2/) {
        exit(0);
    } else {
        warn "H2 listener: rc=$rc\n";
        warn "output: $output\n";
        exit(1);
    }
}

my $cv1 = AE::cv;
my $child_status1;
my $timeout1 = AE::timer(15 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for H2 client (test 1)";
    $cv1->send('timeout');
});
my $child_w1 = AE::child($pid1, sub {
    my ($pid, $status) = @_;
    $child_status1 = $status >> 8;
    $cv1->send('child_done');
});

my $reason1 = $cv1->recv;
isnt $reason1, 'timeout', "H2-enabled listener test did not timeout";
is $child_status1, 0, "nghttp got HTTP/2 response from H2-enabled listener";

# ---------------------------------------------------------------------------
# Test 2: HTTP/1.1 TLS client to H2-disabled listener should work
# ---------------------------------------------------------------------------
@received_requests = ();

my $pid2 = fork();
die "fork failed: $!" unless defined $pid2;

if ($pid2 == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

    my $tls = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port2,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 5 * TIMEOUT_MULT,
    );
    unless ($tls) {
        warn "TLS connect to H2-disabled listener failed: " . IO::Socket::SSL::errstr() . "\n";
        exit(1);
    }

    $tls->print("GET /h1-only HTTP/1.1\r\nHost: localhost:$port2\r\nConnection: close\r\n\r\n");

    my $resp = '';
    while (defined(my $line = $tls->getline())) {
        $resp .= $line;
    }
    $tls->close(SSL_no_shutdown => 1);

    if ($resp =~ /200 OK/ && $resp =~ /scheme=https/) {
        exit(0);
    } else {
        warn "H2-disabled response: $resp\n";
        exit(2);
    }
}

my $cv2 = AE::cv;
my $child_status2;
my $timeout2 = AE::timer(15 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for H1 TLS client (test 2)";
    $cv2->send('timeout');
});
my $child_w2 = AE::child($pid2, sub {
    my ($pid, $status) = @_;
    $child_status2 = $status >> 8;
    $cv2->send('child_done');
});

my $reason2 = $cv2->recv;
isnt $reason2, 'timeout', "H2-disabled listener H1 test did not timeout";
is $child_status2, 0, "HTTP/1.1 TLS client got response from H2-disabled listener";

if (@received_requests) {
    is $received_requests[0]{scheme}, 'https', "H2-disabled listener scheme is https";
    like $received_requests[0]{proto}, qr/HTTP\/1/, "H2-disabled listener protocol is HTTP/1.x";
}

# ---------------------------------------------------------------------------
# Test 3: nghttp to H2-disabled listener should fail H2 negotiation
# ---------------------------------------------------------------------------
@received_requests = ();

my $pid3 = fork();
die "fork failed: $!" unless defined $pid3;

if ($pid3 == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
    my $url = "https://127.0.0.1:$port2/h2-no";
    # nghttp requires h2 ALPN; without it, it should fail or fall back
    my $output = `$nghttp_bin --no-verify $url 2>&1`;
    # The one thing that must be true: h2 was NOT negotiated.
    if ($output =~ /proto=HTTP\/2/) {
        warn "nghttp unexpectedly got HTTP/2 on H2-disabled listener\n";
        exit(1);
    }
    exit(0);
}

my $cv3 = AE::cv;
my $child_status3;
my $timeout3 = AE::timer(15 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for nghttp on H2-disabled listener (test 3)";
    $cv3->send('timeout');
});
my $child_w3 = AE::child($pid3, sub {
    my ($pid, $status) = @_;
    $child_status3 = $status >> 8;
    $cv3->send('child_done');
});

my $reason3 = $cv3->recv;
isnt $reason3, 'timeout', "nghttp to H2-disabled listener did not timeout";
is $child_status3, 0, "nghttp could not negotiate H2 on H2-disabled listener";

# nghttp exits 0 even when it cannot connect at all, so the check above passes
# against a dead port.  Prove positively that the listener is alive and still
# speaks HTTP/1.1 over TLS.  This must run in a forked child: the server is
# this process's event loop, so a blocking client here could never be served.
my $pid4 = fork();
die "fork: $!" unless defined $pid4;
if ($pid4 == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
    my $tls = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port2,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 5 * TIMEOUT_MULT,
    );
    exit(1) unless $tls;
    $tls->print("GET /still-alive HTTP/1.1\r\nHost: localhost:$port2\r\n"
              . "Connection: close\r\n\r\n");
    my $resp = '';
    while (my $line = <$tls>) { $resp .= $line }
    close $tls;
    exit($resp =~ m{^HTTP/1\.1 200} ? 0 : 2);
}

my $cv4 = AE::cv;
my $status4;
my $to4 = AE::timer(15 * TIMEOUT_MULT, 0, sub { $cv4->send('timeout') });
my $cw4 = AE::child($pid4, sub { $status4 = $_[1] >> 8; $cv4->send('done') });
my $reason4 = $cv4->recv;
isnt $reason4, 'timeout', "liveness check on H2-disabled listener did not time out";
is $status4, 0, "H2-disabled listener still serves HTTP/1.1 over TLS";

done_testing;
