#!/usr/bin/env perl
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();
plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 13;

my $CRLF = "\015\012";

#######################################################################
# PART 1: io() over TLS - protocol upgrade echo test
#######################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tls-io: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);

    my $cv = AE::cv;
    my $handler_called = 0;
    my $upgrade_data;

    $feer->request_handler(sub {
        my $req = shift;
        $handler_called = 1;

        my $io = $req->io;
        ok defined($io), 'tls-io: io() returns defined value';
        isa_ok $io, 'IO::Socket', 'tls-io: io() returns IO::Socket';

        # Send 101 upgrade response
        my $response = "HTTP/1.1 101 Switching Protocols${CRLF}"
                     . "Upgrade: test${CRLF}"
                     . "Connection: Upgrade${CRLF}${CRLF}";
        syswrite($io, $response);

        # Echo loop via AnyEvent::Handle
        my $h = AnyEvent::Handle->new(
            fh => $io,
            on_error => sub { $cv->croak("server error: $_[2]") },
        );

        $h->push_read(line => sub {
            $upgrade_data = $_[1];
            $h->push_write("echo: $upgrade_data\n");
            my $t; $t = AE::timer 0.1, 0, sub {
                undef $t;
                $h->destroy;
            };
        });
    });

    my $pid = fork();
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 10 * TIMEOUT_MULT,
        ) or exit(10);

        # Send upgrade request
        $client->print("GET /upgrade HTTP/1.1${CRLF}Host: localhost${CRLF}"
                     . "Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        # Read 101 response
        my $response = '';
        while (my $line = $client->getline()) {
            $response .= $line;
            last if $line eq "${CRLF}";
        }
        exit(11) unless $response =~ /101 Switching/;

        # Send data through tunnel
        $client->print("hello from TLS client\n");

        # Read echo back
        my $echo = $client->getline() // '';
        chomp $echo;

        $client->close(SSL_no_shutdown => 1);
        exit($echo eq 'echo: hello from TLS client' ? 0 : 12);
    }

    my $child_status;
    my $timeout = AE::timer 15 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') };
    my $child_w = AE::child $pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    };
    my $reason = $cv->recv;

    isnt $reason, 'timeout', 'tls-io: did not timeout';
    is $child_status, 0, 'tls-io: client passed (echo over TLS tunnel)';
    ok $handler_called, 'tls-io: handler was called';
    is $upgrade_data, 'hello from TLS client', 'tls-io: server received data through tunnel';
}

#######################################################################
# PART 2: io() over TLS - bidirectional multi-message exchange
#######################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tls-io-bidi: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);

    my $cv = AE::cv;
    my $msg_count = 0;

    $feer->request_handler(sub {
        my $req = shift;
        my $io = $req->io;

        syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}${CRLF}");

        my $h = AnyEvent::Handle->new(
            fh => $io,
            on_error => sub { $cv->croak("server error: $_[2]") },
        );

        my $read_line; $read_line = sub {
            $h->push_read(line => sub {
                my $line = $_[1];
                $msg_count++;
                if ($line eq 'DONE') {
                    $h->push_write("BYE\n");
                    my $t; $t = AE::timer 0.1, 0, sub {
                        undef $t;
                        $h->destroy;
                    };
                } else {
                    $h->push_write("ACK:$line\n");
                    $read_line->();
                }
            });
        };
        $read_line->();
    });

    my $pid = fork();
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 10 * TIMEOUT_MULT,
        ) or exit(10);

        $client->print("GET / HTTP/1.1${CRLF}Host: localhost${CRLF}"
                     . "Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}");

        # Read 101
        my $resp = '';
        while (my $line = $client->getline()) {
            $resp .= $line;
            last if $line eq "${CRLF}";
        }
        exit(11) unless $resp =~ /101/;

        # Exchange 3 messages
        my @acks;
        for my $i (1..3) {
            $client->print("msg$i\n");
            my $ack = $client->getline() // '';
            chomp $ack;
            push @acks, $ack;
        }
        $client->print("DONE\n");
        my $bye = $client->getline() // '';
        chomp $bye;

        $client->close(SSL_no_shutdown => 1);
        exit(0) if $bye eq 'BYE'
                && $acks[0] eq 'ACK:msg1'
                && $acks[1] eq 'ACK:msg2'
                && $acks[2] eq 'ACK:msg3';
        exit(12);
    }

    my $child_status;
    my $timeout = AE::timer 15 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') };
    my $child_w = AE::child $pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    };
    my $reason = $cv->recv;

    isnt $reason, 'timeout', 'tls-io-bidi: did not timeout';
    is $child_status, 0, 'tls-io-bidi: bidirectional exchange passed';
    is $msg_count, 4, 'tls-io-bidi: server received 4 messages (3 + DONE)';
}

#######################################################################
# PART 3: return_from_io on TLS - must croak (tunnel can't be returned)
#######################################################################
{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tls-return-from-io: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);

    my $cv = AE::cv;
    my $croak_msg = '';

    $feer->request_handler(sub {
        my $req = shift;
        my $io = $req->io;
        eval { $req->return_from_io($io) };
        $croak_msg = $@;
        # Connection will be closed since we called io() but didn't upgrade
    });

    my $pid = fork();
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 5 * TIMEOUT_MULT,
        ) or exit(10);
        $client->print("GET /test HTTP/1.1${CRLF}Host: localhost${CRLF}"
                     . "Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}");
        # Server will close after croak
        my $resp = '';
        while (my $line = $client->getline()) { $resp .= $line; last if length($resp) > 1024 }
        $client->close(SSL_no_shutdown => 1);
        exit(0);
    }

    my $child_status;
    my $timeout = AE::timer 10 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') };
    my $child_w = AE::child $pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    };
    my $reason = $cv->recv;
    if ($reason eq 'timeout') { kill 'KILL', $pid; waitpid($pid, 0) }
    like $croak_msg, qr/not supported on TLS tunnel/,
        'tls-return-from-io: croaks on TLS tunnel';
}
