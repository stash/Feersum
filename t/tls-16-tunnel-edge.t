#!perl
# TLS tunnel edge cases:
# - Tunnel survives without read/write timeouts killing it
# - Tunnel properly closes (no keepalive reuse after tunnel)
# - Idle tunnel with keepalive enabled
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";

my $evh_probe = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support"
    unless $evh_probe->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;
plan skip_all => "OpenSSL too old for TLS 1.3" unless tls_client_ok();

my $CRLF = "\015\012";

plan tests => 8;

###########################################################################
# Test 1: TLS tunnel survives past write_timeout
# (write timeout must not kill an active tunnel)
###########################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tunnel-write-timeout: listen';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    $feer->write_timeout(0.5 * TMULT);

    my $cv = AE::cv;
    $feer->request_handler(sub {
        my $req = shift;
        my $io = $req->io;
        syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}${CRLF}");
        my $h = AnyEvent::Handle->new(fh => $io, on_error => sub {});
        $h->push_read(line => sub {
            $h->push_write("echo: $_[1]\n");
            my $t; $t = AE::timer 0.1, 0, sub { undef $t; $h->destroy };
        });
    });

    my $pid = fork();
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TMULT);
        my $c = IO::Socket::SSL->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => 0, Timeout => 10 * TMULT,
        ) or POSIX::_exit(10);
        $c->print("GET / HTTP/1.1${CRLF}Host: l${CRLF}Upgrade: t${CRLF}Connection: Upgrade${CRLF}${CRLF}");
        my $resp = '';
        while (my $l = $c->getline()) { $resp .= $l; last if $l eq $CRLF }
        POSIX::_exit(11) unless $resp =~ /101/;
        # Wait longer than write_timeout before sending data
        select(undef, undef, undef, 1.0 * TMULT);
        $c->print("hello\n");
        my $echo = $c->getline() // '';
        chomp $echo;
        $c->close(SSL_no_shutdown => 1);
        POSIX::_exit($echo eq 'echo: hello' ? 0 : 12);
    }
    my $status;
    my $t = AE::timer(10 * TMULT, 0, sub { $cv->send('timeout') });
    my $w = AE::child($pid, sub { $status = $_[1] >> 8; $cv->send('done') });
    my $r = $cv->recv;
    if ($r eq 'timeout') { kill 'KILL', $pid; waitpid($pid, 0) }
    is $status, 0, 'tunnel-write-timeout: tunnel survives past write_timeout';
}

###########################################################################
# Test 2: TLS tunnel survives past read_timeout
# (read timeout must not kill an idle tunnel)
###########################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tunnel-read-timeout: listen';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    $feer->read_timeout(0.5 * TMULT);

    my $cv = AE::cv;
    $feer->request_handler(sub {
        my $req = shift;
        my $io = $req->io;
        syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}${CRLF}");
        my $h = AnyEvent::Handle->new(fh => $io, on_error => sub {});
        $h->push_read(line => sub {
            $h->push_write("echo: $_[1]\n");
            my $t; $t = AE::timer 0.1, 0, sub { undef $t; $h->destroy };
        });
    });

    my $pid = fork();
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TMULT);
        my $c = IO::Socket::SSL->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => 0, Timeout => 10 * TMULT,
        ) or POSIX::_exit(10);
        $c->print("GET / HTTP/1.1${CRLF}Host: l${CRLF}Upgrade: t${CRLF}Connection: Upgrade${CRLF}${CRLF}");
        my $resp = '';
        while (my $l = $c->getline()) { $resp .= $l; last if $l eq $CRLF }
        POSIX::_exit(11) unless $resp =~ /101/;
        # Wait longer than read_timeout
        select(undef, undef, undef, 1.0 * TMULT);
        $c->print("hello\n");
        my $echo = $c->getline() // '';
        chomp $echo;
        $c->close(SSL_no_shutdown => 1);
        POSIX::_exit($echo eq 'echo: hello' ? 0 : 12);
    }
    my $status;
    my $t = AE::timer(10 * TMULT, 0, sub { $cv->send('timeout') });
    my $w = AE::child($pid, sub { $status = $_[1] >> 8; $cv->send('done') });
    my $r = $cv->recv;
    if ($r eq 'timeout') { kill 'KILL', $pid; waitpid($pid, 0) }
    is $status, 0, 'tunnel-read-timeout: tunnel survives past read_timeout';
}

###########################################################################
# Test 3: TLS tunnel with keepalive=1 closes properly
# (tunnel connections should not be reused for HTTP even with keepalive)
###########################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tunnel-keepalive-close: listen';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    $feer->set_keepalive(1);

    my $cv = AE::cv;
    my $handler_calls = 0;
    $feer->request_handler(sub {
        my $req = shift;
        $handler_calls++;
        my $io = $req->io;
        syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}${CRLF}");
        syswrite($io, "hello\n");
        # Close the io handle - tunnel shuts down
        my $t; $t = AE::timer 0.1, 0, sub {
            undef $t;
            POSIX::close(fileno($io)) if defined fileno($io);
        };
    });

    my $pid = fork();
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TMULT);
        my $c = IO::Socket::SSL->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => 0, Timeout => 5 * TMULT,
        ) or POSIX::_exit(10);
        $c->print("GET / HTTP/1.1${CRLF}Host: l${CRLF}Upgrade: t${CRLF}Connection: keep-alive${CRLF}${CRLF}");
        my $resp = '';
        while (my $l = $c->getline()) { $resp .= $l; last if $l eq $CRLF }
        POSIX::_exit(11) unless $resp =~ /101/;
        # Read tunnel data
        my $data = $c->getline() // '';
        # Connection should be closed after tunnel EOF, not reused
        my $more = $c->getline();
        $c->close(SSL_no_shutdown => 1);
        POSIX::_exit(defined $more ? 1 : 0);
    }
    my $status;
    my $t = AE::timer(10 * TMULT, 0, sub { $cv->send('timeout') });
    my $w = AE::child($pid, sub { $status = $_[1] >> 8; $cv->send('done') });
    my $r = $cv->recv;
    if ($r eq 'timeout') { kill 'KILL', $pid; waitpid($pid, 0) }
    isnt $r, 'timeout', 'tunnel-keepalive-close: did not timeout';
    is $status, 0, 'tunnel-keepalive-close: connection closed (not reused)';
    is $handler_calls, 1, 'tunnel-keepalive-close: handler called once';
}
