#!perl
# TLS lifecycle edge cases:
# - unlisten() frees TLS context (bug 4 regression)
# - graceful_shutdown frees TLS context (bug 9 regression)
# - POST body arriving with handshake completion (bugs 10/11 regression)
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";

plan skip_all => "Feersum not compiled with TLS support"
    unless Feersum->new()->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;
plan skip_all => "OpenSSL too old for TLS 1.3" unless tls_client_ok();

my $CRLF = "\015\012";

plan tests => 10;

###########################################################################
# Test 1: unlisten() on TLS listener - no crash, resources freed
###########################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'unlisten-tls: listen';

    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    $feer->request_handler(sub {
        $_[0]->send_response(200, ['Content-Type' => 'text/plain'], \"ok");
    });

    # Verify TLS works before unlisten
    run_client("unlisten-tls-before", sub {
        my $c = IO::Socket::SSL->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => 0, Timeout => 5 * TMULT,
        ) or return 10;
        $c->print("GET / HTTP/1.1${CRLF}Host: l${CRLF}Connection: close${CRLF}${CRLF}");
        my $r = ''; while (my $l = $c->getline()) { $r .= $l }
        $c->close(SSL_no_shutdown => 1);
        return $r =~ /ok/ ? 0 : 11;
    });

    # unlisten - should free TLS context without crash
    $feer->unlisten();
    pass 'unlisten-tls: unlisten completed without crash';
}

###########################################################################
# Test 2: graceful_shutdown on TLS listener - no crash
###########################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'shutdown-tls: listen';

    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    $feer->request_handler(sub {
        $_[0]->send_response(200, ['Content-Type' => 'text/plain'], \"ok");
    });

    my $shutdown_done = 0;
    $feer->graceful_shutdown(sub { $shutdown_done = 1 });

    # Pump the event loop briefly for the shutdown callback
    my $cv = AE::cv;
    my $t = AE::timer(1 * TMULT, 0, sub { $cv->send });
    $cv->recv;

    ok $shutdown_done, 'shutdown-tls: shutdown callback fired';
}

###########################################################################
# Test 3: TLS POST with body - body received correctly
# Exercises bug 10/11: received_cl update after post-handshake drain
###########################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tls-post: listen';

    my $feer = Feersum->new_instance();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);

    my $cv = AE::cv;
    my $got_body = '';
    $feer->request_handler(sub {
        my $r = shift;
        my $env = $r->env();
        my $input = $env->{'psgi.input'};
        if ($input) {
            $input->read($got_body, $env->{CONTENT_LENGTH} || 0);
            $input->close;
        }
        $r->send_response(200, ['Content-Type' => 'text/plain',
                                'Content-Length' => length($got_body)],
                          \$got_body);
    });

    run_client("tls-post-body", sub {
        my $c = IO::Socket::SSL->new(
            PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => 0, Timeout => 5 * TMULT,
        ) or return 10;
        # Send POST with body - IO::Socket::SSL may coalesce with handshake
        my $body = "X" x 1024;
        $c->print("POST /test HTTP/1.1${CRLF}Host: l${CRLF}"
                . "Content-Length: " . length($body) . "${CRLF}"
                . "Connection: close${CRLF}${CRLF}$body");
        my $resp = '';
        while (my $l = $c->getline()) { $resp .= $l }
        $c->close(SSL_no_shutdown => 1);
        return $resp =~ /X{1024}/ ? 0 : 11;
    });

    is length($got_body), 1024, 'tls-post: server received full 1024-byte body';
}
