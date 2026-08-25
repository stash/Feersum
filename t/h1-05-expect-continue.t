#!/usr/bin/env perl
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use AnyEvent::Handle;

#######################################################################
# PART 1: Native Feersum interface tests
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'native: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->request_handler(sub {
        my $r = shift;
        my $env = $r->env;
        my $body = '';
        if (my $cl = $env->{CONTENT_LENGTH}) {
            $env->{'psgi.input'}->read($body, $cl);
        }
        my $resp = "len=" . length($body);
        $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
    });

    # Test 1: POST with Expect: 100-continue
    {
        my $cv = AE::cv;
        my $got_continue = 0;
        my $full_response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n");

        $h->on_read(sub {
            my $data = $h->rbuf;
            $h->rbuf = '';
            $full_response .= $data;

            if (!$got_continue && $data =~ /100 Continue/) {
                $got_continue = 1;
                $h->push_write("0123456789");
            }
            if ($full_response =~ /len=\d+/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($full_response, qr/100 Continue/i, 'native: Got 100 Continue response');
        like($full_response, qr/200 OK/, 'native: Got 200 OK final response');
        like($full_response, qr/len=10/, 'native: Body was received correctly (10 bytes)');
    }

    # Test 2: Unknown Expect value should get 417
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nExpect: something-weird\r\nConnection: close\r\n\r\nhello");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /HTTP\/1\.\d \d{3}/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/417 Expectation Failed/, 'native: Unknown Expect value gets 417');
    }
}

#######################################################################
# PART 2: PSGI interface tests
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'psgi: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);

    my $app = sub {
        my $env = shift;
        my $body = '';
        if (my $cl = $env->{CONTENT_LENGTH}) {
            $env->{'psgi.input'}->read($body, $cl);
        }
        my $resp = "len=" . length($body);
        return [200, ['Content-Type' => 'text/plain'], [$resp]];
    };

    $feer->psgi_request_handler($app);

    # Test 1: POST with Expect: 100-continue
    {
        my $cv = AE::cv;
        my $got_continue = 0;
        my $full_response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n");

        $h->on_read(sub {
            my $data = $h->rbuf;
            $h->rbuf = '';
            $full_response .= $data;

            if (!$got_continue && $data =~ /100 Continue/) {
                $got_continue = 1;
                $h->push_write("0123456789");
            }
            if ($full_response =~ /len=\d+/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($full_response, qr/100 Continue/i, 'psgi: Got 100 Continue response');
        like($full_response, qr/200 OK/, 'psgi: Got 200 OK final response');
        like($full_response, qr/len=10/, 'psgi: Body was received correctly (10 bytes)');
    }

    # Test 2: Normal POST without Expect header (sanity check)
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /len=\d+/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/len=5/, 'psgi: Normal POST without Expect works');
    }

    # Test 3: Unknown Expect value should get 417
    {
        my $cv = AE::cv;
        my $response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        $h->push_write("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nExpect: something-weird\r\nConnection: close\r\n\r\nhello");

        $h->on_read(sub {
            $response .= $h->rbuf;
            $h->rbuf = '';
            if ($response =~ /HTTP\/1\.\d \d{3}/) {
                $cv->send;
            }
        });

        my $timer = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($response, qr/417 Expectation Failed/, 'psgi: Unknown Expect value gets 417');
    }
}

#######################################################################
# PART 3: 100-continue over TLS
#######################################################################
SKIP: {
    my $evh_tls = Feersum->new();
    skip "Feersum not compiled with TLS support", 5 unless $evh_tls->has_tls();

    my $cert_file = 'eg/ssl-proxy/server.crt';
    my $key_file  = 'eg/ssl-proxy/server.key';
    skip "no test certificates", 5 unless -f $cert_file && -f $key_file;

    eval { require IO::Socket::SSL; 1 }
        or skip "IO::Socket::SSL not installed", 5;
    skip "OpenSSL too old for TLS 1.3 client", 5 unless tls_client_ok();

    my ($socket, $port) = get_listen_socket();
    ok $socket, 'tls: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->set_tls(cert_file => $cert_file, key_file => $key_file);
    $feer->request_handler(sub {
        my $r = shift;
        my $env = $r->env;
        my $body = '';
        if (my $cl = $env->{CONTENT_LENGTH}) {
            $env->{'psgi.input'}->read($body, $cl);
        }
        my $resp = "len=" . length($body);
        $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
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

        # Send POST with Expect: 100-continue (headers only, no body yet)
        $client->print("POST /test HTTP/1.1\r\nHost: localhost\r\n"
                     . "Content-Length: 10\r\nExpect: 100-continue\r\n"
                     . "Connection: close\r\n\r\n");

        # Read 100 Continue response line
        my $line100 = $client->getline() // '';
        exit(11) unless $line100 =~ /100 Continue/i;
        # Consume blank line after 100
        while (my $l = $client->getline()) { last if $l eq "\r\n"; }

        # Now send the body
        $client->print("0123456789");

        # Read final response
        my $resp = '';
        while (my $l = $client->getline()) { $resp .= $l; }
        $client->close(SSL_no_shutdown => 1);

        exit(0) if $resp =~ /200 OK/ && $resp =~ /len=10/;
        exit(12);
    }

    my $cv = AE::cv;
    my $child_status;
    my $timeout = AE::timer 10 * TIMEOUT_MULT, 0, sub { $cv->send('timeout') };
    my $child_w = AE::child $pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    };
    my $reason = $cv->recv;

    isnt $reason, 'timeout', 'tls: did not timeout';
    is $child_status, 0, 'tls: 100-continue works over TLS';

    # Also test 417 over TLS
    my $pid2 = fork();
    if ($pid2 == 0) {
        select(undef, undef, undef, 0.3 * TIMEOUT_MULT);
        my $client = IO::Socket::SSL->new(
            PeerAddr        => '127.0.0.1',
            PeerPort        => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout         => 5 * TIMEOUT_MULT,
        ) or exit(10);

        $client->print("POST /test HTTP/1.1\r\nHost: localhost\r\n"
                     . "Content-Length: 5\r\nExpect: something-weird\r\n"
                     . "Connection: close\r\n\r\nhello");

        my $resp = '';
        while (my $line = $client->getline()) {
            $resp .= $line;
            last if $resp =~ /417|200/;
        }
        $client->close(SSL_no_shutdown => 1);
        exit($resp =~ /417 Expectation Failed/ ? 0 : 12);
    }

    my $cv2 = AE::cv;
    my $child_status2;
    my $timeout2 = AE::timer 10 * TIMEOUT_MULT, 0, sub { $cv2->send('timeout') };
    my $child_w2 = AE::child $pid2, sub {
        $child_status2 = $_[1] >> 8;
        $cv2->send('child_done');
    };
    my $reason2 = $cv2->recv;

    isnt $reason2, 'timeout', 'tls-417: did not timeout';
    is $child_status2, 0, 'tls-417: unknown Expect gets 417 over TLS';
}

#######################################################################
# PART 4: Expect: 100-continue with chunked Transfer-Encoding
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, 'chunked+expect: made listen socket';

    my $feer = Feersum->new();
    $feer->use_socket($socket);
    $feer->request_handler(sub {
        my $r = shift;
        my $env = $r->env;
        my $body = '';
        my $input = $env->{'psgi.input'};
        while ($input->read(my $buf, 4096)) {
            $body .= $buf;
        }
        my $resp = "len=" . length($body);
        $r->send_response(200, ['Content-Type' => 'text/plain'], \$resp);
    });

    # Test: POST with Expect: 100-continue + Transfer-Encoding: chunked
    {
        my $cv = AE::cv;
        my $got_continue = 0;
        my $full_response = '';

        my $h = AnyEvent::Handle->new(
            connect => ['localhost', $port],
            on_error => sub { $cv->send; },
            on_eof => sub { $cv->send; },
        );

        # Send headers only (no body yet) - chunked TE, Expect: 100-continue
        $h->push_write(
            "POST /test HTTP/1.1\r\n" .
            "Host: localhost\r\n" .
            "Transfer-Encoding: chunked\r\n" .
            "Expect: 100-continue\r\n" .
            "Connection: close\r\n" .
            "\r\n"
        );

        $h->on_read(sub {
            my $data = $h->rbuf;
            $h->rbuf = '';
            $full_response .= $data;

            if (!$got_continue && $full_response =~ /100 Continue/) {
                $got_continue = 1;
                # Send chunked body: "hello" (5 bytes)
                $h->push_write("5\r\nhello\r\n0\r\n\r\n");
            }
        });

        my $timer = AE::timer 3 * TIMEOUT_MULT, 0, sub { $cv->send; };
        $cv->recv;

        like($full_response, qr/100 Continue/i, 'chunked+expect: Got 100 Continue');
        like($full_response, qr/200 OK/, 'chunked+expect: Got 200 OK');
        like($full_response, qr/len=5/, 'chunked+expect: Body received correctly (5 bytes)');
    }
}

done_testing;
