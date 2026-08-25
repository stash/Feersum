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

my @received_requests;
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    my $path = $env->{PATH_INFO} || $env->{REQUEST_URI} || '/';
    my $scheme = $env->{'psgi.url_scheme'} || 'http';
    my $proto  = $env->{SERVER_PROTOCOL}   || 'HTTP/1.0';
    push @received_requests, { path => $path, scheme => $scheme, proto => $proto };

    my $body = "path=$path scheme=$scheme proto=$proto";
    $r->send_response("200 OK", [
        'Content-Type'   => 'text/plain',
        'Content-Length' => length($body),
        'Connection'     => 'close',
    ], $body);
});

# Fork: child runs TLS client, parent runs event loop
my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    # Child process: TLS client
    # Small delay to let parent enter event loop
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

    $client->print(
        "GET /hello HTTP/1.1\r\n" .
        "Host: localhost:$port\r\n" .
        "Connection: close\r\n" .
        "\r\n"
    );

    my $response = '';
    while (defined(my $line = $client->getline())) {
        $response .= $line;
    }
    $client->close(SSL_no_shutdown => 1);

    if ($response =~ /200 OK/ && $response =~ /scheme=https/) {
        exit(0);
    } else {
        warn "Unexpected response: $response\n";
        exit(2);
    }
}

# Parent: run event loop until child finishes or timeout
my $cv = AE::cv;
my $child_status;
my $timeout = AE::timer(10 * TIMEOUT_MULT, 0, sub {
    diag "timeout waiting for TLS client";
    $cv->send('timeout');
});
my $child_w = AE::child($pid, sub {
    my ($pid, $status) = @_;
    $child_status = $status >> 8;
    $cv->send('child_done');
});

my $reason = $cv->recv;
isnt $reason, 'timeout', "did not timeout";

is $child_status, 0, "TLS client connected and got valid response";

cmp_ok scalar(@received_requests), '>=', 1,
    "server received request(s) over TLS (got " . scalar(@received_requests) . ")";

if (@received_requests) {
    is $received_requests[0]{scheme}, 'https', "psgi.url_scheme is https for TLS";
    is $received_requests[0]{path}, '/hello', "request path correct";
}

done_testing;
