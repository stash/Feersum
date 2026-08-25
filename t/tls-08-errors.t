#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
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

# Test 1: set_tls with invalid cert_file
{
    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    ok $socket, "got listen socket for invalid cert test";
    $f->use_socket($socket);
    eval { $f->set_tls(cert_file => '/nonexistent/cert.pem', key_file => $key_file) };
    like $@, qr/failed to|error/i, "set_tls croaks on invalid cert_file";
}

# Test 2: set_tls with invalid key_file
{
    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    ok $socket, "got listen socket for invalid key test";
    $f->use_socket($socket);
    eval { $f->set_tls(cert_file => $cert_file, key_file => '/nonexistent/key.pem') };
    like $@, qr/failed to|error/i, "set_tls croaks on invalid key_file";
}

# Test 3: set_tls with missing required params
{
    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    $f->use_socket($socket);
    eval { $f->set_tls(cert_file => $cert_file) };
    like $@, qr/key_file is required/, "set_tls croaks on missing key_file";

    eval { $f->set_tls(key_file => $key_file) };
    like $@, qr/cert_file is required/, "set_tls croaks on missing cert_file";
}

# Test 4: set_tls with no listeners (need new_instance since new() is singleton)
{
    my $f = Feersum->new_instance();
    eval { $f->set_tls(cert_file => $cert_file, key_file => $key_file) };
    like $@, qr/no listeners/, "set_tls croaks when no listeners configured";
}

# Test 5: set_tls with listener index out of range
{
    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    $f->use_socket($socket);
    # Use a clearly-impossible index: 5 was out of range only because this
    # file happens to create exactly four listeners.
    eval { $f->set_tls(listener => 999, cert_file => $cert_file, key_file => $key_file) };
    like $@, qr/out of range/, "set_tls croaks on listener index out of range";

    # Past 32 bits the index used to wrap to 0 and configure a listener the
    # caller never named.  1e30 and Inf are NVs everywhere, so they exercise
    # the NV range check even where an IV holds 2**32.
    for my $huge (4294967296, 4294967297, 1e30, 9**9**9) {
        eval { $f->set_tls(listener => $huge, cert_file => $cert_file,
                           key_file => $key_file) };
        like $@, qr/out of range/,
            "set_tls croaks on listener index $huge rather than wrapping to a real one";
    }
}

# Test 6: set_tls with valid listener index
{
    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    $f->use_socket($socket);
    eval { $f->set_tls(listener => 0, cert_file => $cert_file, key_file => $key_file) };
    is $@, '', "set_tls with listener => 0 succeeds";
}

# Test 7: set_tls with unknown option
{
    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    $f->use_socket($socket);
    eval { $f->set_tls(cert_file => $cert_file, key_file => $key_file, bogus => 1) };
    like $@, qr/unknown option/, "set_tls croaks on unknown option";
}

# Test 8: bad TLS client doesn't crash the server
SKIP: {
    eval { require IO::Socket::SSL; 1 }
        or skip "IO::Socket::SSL not installed", 3;
    skip "OpenSSL too old for TLS 1.3 client", 3 unless tls_client_ok();

    my $f = Feersum->new();
    my ($socket, $port) = get_listen_socket();
    ok $socket, "got listen socket for bad client test on port $port";
    $f->use_socket($socket);
    $f->set_tls(cert_file => $cert_file, key_file => $key_file);

    my $request_count = 0;
    $f->request_handler(sub {
        my $r = shift;
        $request_count++;
        $r->send_response("200 OK", [
            'Content-Type'   => 'text/plain',
            'Content-Length' => 2,
            'Connection'     => 'close',
        ], "OK");
    });

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

        # Send plain text (not TLS) to a TLS port - server should handle gracefully
        my $plain = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 3 * TIMEOUT_MULT,
        );
        if ($plain) {
            print $plain "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
            select(undef, undef, undef, 0.5 * TIMEOUT_MULT);
            # A TLS listener must never answer cleartext HTTP.  The reply was
            # previously never read, so a TLS-bypass regression was invisible.
            my $reply = '';
            eval {
                local $SIG{ALRM} = sub { die "to\n" };
                alarm(2 * TIMEOUT_MULT);
                sysread($plain, $reply, 512);
                alarm(0);
            };
            alarm(0);
            close $plain;
            exit(5) if $reply =~ m{^HTTP/1\.};
        }

        # Now try a proper TLS connection - should still work
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 5 * TIMEOUT_MULT,
        );
        unless ($client) {
            warn "TLS connect after bad client failed: " . IO::Socket::SSL::errstr() . "\n";
            exit(1);
        }

        $client->print(
            "GET /after-bad HTTP/1.1\r\n" .
            "Host: localhost:$port\r\n" .
            "Connection: close\r\n" .
            "\r\n"
        );

        my $response = '';
        while (defined(my $line = $client->getline())) {
            $response .= $line;
        }
        $client->close(SSL_no_shutdown => 1);

        if ($response =~ /200 OK/) {
            exit(0);
        } else {
            warn "Bad response after bad client: $response\n";
            exit(2);
        }
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(10 * TIMEOUT_MULT, 0, sub {
        diag "timeout in bad client test";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        my ($pid, $status) = @_;
        $child_status = $status >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "bad client test did not timeout";
    is $child_status, 0, "server survived bad TLS client and still serves valid ones";
}

done_testing;
