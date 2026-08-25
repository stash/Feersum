#!perl
# Test TLS handshake timeout/stall behavior.
# Verifies server doesn't hang on incomplete TLS handshakes and
# remains functional after bad clients disconnect.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available"
    if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';

plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file) };
is $@, '', "set_tls with valid cert/key";

# Short read_timeout so tests complete quickly
$evh->read_timeout(2 * TIMEOUT_MULT);

my $request_count = 0;
$evh->request_handler(sub {
    my $r = shift;
    $request_count++;
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
});

# ========================================================================
# Test 1: Incomplete TLS handshake (send partial ClientHello, then stop)
# Server should eventually close the connection via read_timeout.
# ========================================================================
{
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

        # Connect but send only a partial TLS ClientHello
        my $raw = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5 * TIMEOUT_MULT,
        );
        exit(1) unless $raw;

        # TLS record header: ContentType=Handshake(0x16), Version=TLS1.0(0x0301),
        # Length=5 (but we only send 2 bytes of payload - incomplete)
        $raw->syswrite(pack("Cnn", 0x16, 0x0301, 5));
        $raw->syswrite("\x01\x00");  # partial ClientHello

        # The server must close a stalled handshake.  Distinguish that from
        # "we gave up waiting": exit non-zero if we were NOT closed, otherwise
        # this test passes even with the handshake timeout disabled.
        my $buf;
        my $t0 = time;
        my $closed = 0;
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm(6 * TIMEOUT_MULT);
            my $n = $raw->sysread($buf, 4096);
            alarm(0);
            # EOF (0) or a TLS alert both mean the server dropped us.
            $closed = 1 if defined $n;
        };
        alarm(0);
        $raw->close();
        exit($closed ? 0 : 20);
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(10 * TIMEOUT_MULT, 0, sub {
        diag "timeout waiting for partial handshake test";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "partial TLS handshake: did not hang";
    is $child_status, 0, "partial TLS handshake: client exited cleanly";
}

# ========================================================================
# Test 2: Garbage bytes sent to TLS port
# Server should close immediately (handshake error, not timeout).
# ========================================================================
{
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);

        my $raw = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 5 * TIMEOUT_MULT,
        );
        exit(1) unless $raw;

        $raw->syswrite("THIS IS NOT TLS AT ALL\r\n");

        # Server should close quickly (not wait for read_timeout).  $n used to
        # be captured and discarded with an unconditional exit(0), so a TLS
        # listener answering cleartext garbage with a plain HTTP response
        # passed.  n == 0 or undef means the server closed - expected.
        my $buf;
        my $n = $raw->sysread($buf, 4096);
        $raw->close();
        exit(21) if $n && $buf =~ m{^HTTP/1\.};  # cleartext bypass
        exit(22) if !defined $n;                 # read error, not a clean close
        exit(0);
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(5 * TIMEOUT_MULT, 0, sub {
        diag "timeout waiting for garbage test";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "garbage bytes: did not hang";
    is $child_status, 0, "garbage bytes: connection closed cleanly";
}

# ========================================================================
# Test 3: Server still works after bad TLS clients
# ========================================================================
{
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, 0.5 * TIMEOUT_MULT);

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

        exit($response =~ /200 OK/ ? 0 : 2);
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(10 * TIMEOUT_MULT, 0, sub {
        diag "timeout waiting for recovery test";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "recovery: did not timeout";
    is $child_status, 0, "recovery: good TLS request succeeds after bad clients";
}

# ========================================================================
# Test 4: Multiple simultaneous incomplete handshakes don't exhaust server
# ========================================================================
{
    my @pids;
    for my $i (1..5) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            select(undef, undef, undef, 0.2 * TIMEOUT_MULT);
            my $raw = IO::Socket::INET->new(
                PeerAddr => '127.0.0.1',
                PeerPort => $port,
                Proto    => 'tcp',
                Timeout  => 3 * TIMEOUT_MULT,
            );
            exit(1) unless $raw;
            # Send TLS record header but no payload
            $raw->syswrite(pack("Cnn", 0x16, 0x0301, 100));
            select(undef, undef, undef, 4 * TIMEOUT_MULT);
            $raw->close();
            exit(0);
        }
        push @pids, $pid;
    }

    # After the bad clients are connected, a good client should still work
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        select(undef, undef, undef, 1.0 * TIMEOUT_MULT);
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 8 * TIMEOUT_MULT,
        );
        unless ($client) {
            warn "TLS connect failed with 5 stalled clients: " . IO::Socket::SSL::errstr() . "\n";
            exit(1);
        }
        $client->print("GET /concurrent-bad HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        my $resp = '';
        while (defined(my $line = $client->getline())) { $resp .= $line; }
        $client->close(SSL_no_shutdown => 1);
        exit($resp =~ /200 OK/ ? 0 : 2);
    }

    my $cv = AE::cv;
    my $good_status;
    my $t = AE::timer(15 * TIMEOUT_MULT, 0, sub {
        diag "timeout waiting for concurrent bad clients test";
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $good_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    isnt $reason, 'timeout', "concurrent stalls: did not timeout";
    is $good_status, 0, "concurrent stalls: good client succeeds despite 5 stalled handshakes";

    # Reap stalled children
    for my $p (@pids) {
        kill 'TERM', $p;
        waitpid($p, 0);
    }
}

done_testing;
