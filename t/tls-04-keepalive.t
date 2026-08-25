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

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);

eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file) };
is $@, '', "set_tls with valid cert/key";

$evh->set_keepalive(1);

my @received_requests;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    my $path = $env->{PATH_INFO} || '/';
    push @received_requests, $path;

    my $body = "path=$path num=" . scalar(@received_requests);
    $r->send_response("200 OK", [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($body),
    ], $body);
});

# Test 1: TLS keepalive - two sequential requests on one connection
my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

    my $client = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 5 * TIMEOUT_MULT,
    );
    unless ($client) {
        warn "TLS connect failed: " . IO::Socket::SSL::errstr() . "\n";
        exit(1);
    }

    # Helper: read one full HTTP response (headers + Content-Length body)
    my $read_response = sub {
        my $hdrs = '';
        while (defined(my $line = $client->getline())) {
            $hdrs .= $line;
            last if $hdrs =~ /\r\n\r\n$/;
        }
        my $body = '';
        if ($hdrs =~ /Content-Length:\s*(\d+)/i) {
            my $cl = $1;
            while (length($body) < $cl) {
                my $n = $client->read($body, $cl - length($body), length($body));
                last if !defined($n) || $n == 0;
            }
        }
        return $hdrs . $body;
    };

    # First request with keep-alive
    $client->print(
        "GET /first HTTP/1.1\r\n" .
        "Host: localhost:$port\r\n" .
        "Connection: keep-alive\r\n" .
        "\r\n"
    );

    my $resp1 = $read_response->();
    unless ($resp1 =~ /200 OK/ && $resp1 =~ /path=\/first/) {
        warn "First response bad: $resp1\n";
        exit(2);
    }

    # Second request on same connection
    $client->print(
        "GET /second HTTP/1.1\r\n" .
        "Host: localhost:$port\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    my $resp2 = $read_response->();
    $client->close(SSL_no_shutdown => 1);

    unless ($resp2 =~ /200 OK/ && $resp2 =~ /path=\/second/) {
        warn "Second response bad: $resp2\n";
        exit(3);
    }

    exit(0);
}

# Parent: run event loop
my $cv = AE::cv;
my $child_status;
my $timeout = AE::timer(15 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for TLS keepalive client";
    $cv->send('timeout');
});
my $child_w = AE::child($pid, sub {
    my ($pid, $status) = @_;
    $child_status = $status >> 8;
    $cv->send('child_done');
});

my $reason = $cv->recv;
isnt $reason, 'timeout', "keepalive test did not timeout";
is $child_status, 0, "TLS keepalive client got both responses";

cmp_ok scalar(@received_requests), '==', 2,
    "server received 2 requests over keepalive TLS";

if (@received_requests >= 2) {
    is $received_requests[0], '/first', "first request path correct";
    is $received_requests[1], '/second', "second request path correct";
}

# Test 2: TLS pipelining - send two requests without waiting for first response
@received_requests = ();

my $pid2 = fork();
die "fork failed: $!" unless defined $pid2;

if ($pid2 == 0) {
    select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

    my $client = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 5 * TIMEOUT_MULT,
    );
    unless ($client) {
        warn "TLS connect failed: " . IO::Socket::SSL::errstr() . "\n";
        exit(1);
    }

    # Send both requests at once (pipelined)
    $client->print(
        "GET /pipe1 HTTP/1.1\r\n" .
        "Host: localhost:$port\r\n" .
        "\r\n" .
        "GET /pipe2 HTTP/1.1\r\n" .
        "Host: localhost:$port\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    # Read all responses
    my $all = '';
    while (defined(my $line = $client->getline())) {
        $all .= $line;
    }
    $client->close(SSL_no_shutdown => 1);

    my @responses = split(/(?=HTTP\/1\.1)/, $all);
    if (@responses >= 2 &&
        $responses[0] =~ /path=\/pipe1/ &&
        $responses[1] =~ /path=\/pipe2/) {
        exit(0);
    } else {
        warn "Pipeline responses: got " . scalar(@responses) . " responses\n";
        warn "Full: $all\n";
        exit(4);
    }
}

my $cv2 = AE::cv;
my $child_status2;
my $timeout2 = AE::timer(15 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for TLS pipeline client";
    $cv2->send('timeout');
});
my $child_w2 = AE::child($pid2, sub {
    my ($pid, $status) = @_;
    $child_status2 = $status >> 8;
    $cv2->send('child_done');
});

my $reason2 = $cv2->recv;
isnt $reason2, 'timeout', "pipeline test did not timeout";
is $child_status2, 0, "TLS pipeline client got both pipelined responses";

cmp_ok scalar(@received_requests), '==', 2,
    "server received 2 pipelined requests over TLS";

if (@received_requests >= 2) {
    is $received_requests[0], '/pipe1', "first pipelined request path correct";
    is $received_requests[1], '/pipe2', "second pipelined request path correct";
}

done_testing;
