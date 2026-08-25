#!perl
use warnings;
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More tests => 25;
use lib 't'; use Utils;

# Test poll_read_cb for streaming body reads with Expect: 100-continue
# and return_from_psgix_io for keepalive after psgix.io access
# Tests both PSGI and native Feersum interfaces

BEGIN { use_ok('Feersum') };

my $CRLF = "\015\012";

#######################################################################
# PART 1: Native Feersum interface tests
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "native: made listen socket";

    my $evh = Feersum->new();
    $evh->use_socket($socket);

    {
        no warnings 'redefine';
        *Feersum::DIED = sub {
            my $err = shift;
            fail "native: Died during request handler: $err";
        };
    }

    my $cv = AE::cv;
    my $streaming_body = '';

    # Native interface uses request_handler
    $evh->request_handler(sub {
        my $r = shift;
        my $env = $r->env();

        isa_ok $r, 'Feersum::Connection', 'native: got connection object';

        my $input = $env->{'psgi.input'};
        isa_ok $input, 'Feersum::Connection::Reader', 'native: got reader handle';

        $streaming_body = '';

        my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain']);

        $input->poll_cb(sub {
            my $reader = shift;

            my $buf;
            my $n = $reader->read($buf, 1024);
            if ($n && $n > 0) {
                $streaming_body .= $buf;
                pass "native: read chunk: $n bytes";
            }

            # Check if we got all the data
            if (length($streaming_body) >= $env->{CONTENT_LENGTH}) {
                $reader->poll_cb(undef);  # unset callback
                $w->write("NATIVE: $streaming_body");
                $w->close();
            }
        });
    });

    $cv->begin;
    my $h1;
    $h1 = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "native: test error: $msg";
            $cv->end;
        },
    );

    my $body = 'Hello native world!';
    $h1->push_write(
        "POST /test HTTP/1.1$CRLF" .
        "Host: localhost$CRLF" .
        "Content-Length: " . length($body) . "$CRLF" .
        "Expect: 100-continue$CRLF" .
        "$CRLF"
    );

    $h1->push_read(regex => qr/100 Continue.*?$CRLF$CRLF/s, sub {
        my ($h, $data) = @_;
        like $data, qr/100 Continue/, 'native: got 100 Continue';

        $h->push_write($body);

        $h->push_read(regex => qr/$CRLF$CRLF/, sub {
            my ($h, $headers) = @_;
            like $headers, qr/200 OK/, 'native: got 200 response';

            $h->push_read(regex => qr/0\r\n\r\n/, sub {
                my ($h, $data) = @_;
                like $data, qr/NATIVE: Hello native world!/, 'native: body echoed correctly';
                $cv->end;
                $h->destroy;
                undef $h1;
            });
        });
    });

    $cv->recv;
    pass "native: poll_read_cb test complete";
}

#######################################################################
# PART 2: PSGI interface tests
#######################################################################

{
    my ($socket, $port) = get_listen_socket();
    ok $socket, "psgi: made listen socket";

    my $evh = Feersum->new();
    $evh->use_socket($socket);
    $evh->set_keepalive(1);

    {
        no warnings 'redefine';
        *Feersum::DIED = sub {
            my $err = shift;
            fail "psgi: Died during request handler: $err";
        };
    }

    my $cv = AE::cv;
    my $streaming_body = '';
    my @kept_handles;

    # PSGI interface uses psgi_request_handler
    my $app = sub {
        my $env = shift;
        my $test_type = $env->{HTTP_X_TEST} || '';

        if ($test_type eq 'streaming') {
            return sub {
                my $respond = shift;
                my $input = $env->{'psgi.input'};
                isa_ok $input, 'Feersum::Connection::Reader', 'psgi: got reader handle';

                $streaming_body = '';

                my $writer = $respond->([200, ['Content-Type' => 'text/plain']]);

                $input->poll_cb(sub {
                    my $reader = shift;

                    my $buf;
                    my $n = $reader->read($buf, 1024);
                    if ($n && $n > 0) {
                        $streaming_body .= $buf;
                        pass "psgi: read chunk: $n bytes";
                    }

                    if (length($streaming_body) >= $env->{CONTENT_LENGTH}) {
                        $reader->poll_cb(undef);
                        $writer->write("PSGI: $streaming_body");
                        $writer->close();
                    }
                });
            };
        }
        elsif ($test_type eq 'psgix-return') {
            return sub {
                my $respond = shift;
                my $io = $env->{'psgix.io'};
                isa_ok $io, 'IO::Socket', 'psgi: got psgix.io handle';

                my $secret;
                read $io, $secret, 6;
                is $secret, 'SECRET', 'psgi: read secret from psgix.io';

                my $input = $env->{'psgi.input'};
                my $pulled = $input->return_from_psgix_io($io);
                ok defined($pulled), 'psgi: return_from_psgix_io returned';

                $io->autoflush(1);
                print $io "HTTP/1.1 200 OK${CRLF}Content-Type: text/plain${CRLF}Content-Length: 2${CRLF}Connection: keep-alive${CRLF}${CRLF}OK";

                push @kept_handles, $io;
            };
        }
        elsif ($test_type eq 'keepalive-after') {
            pass "psgi: received second request on keepalive connection";
            return [200, ['Content-Type' => 'text/plain'], ['KEEPALIVE']];
        }
        else {
            return [200, ['Content-Type' => 'text/plain'], ['DEFAULT']];
        }
    };

    $evh->psgi_request_handler($app);

    # Test streaming body read
    $cv->begin;
    my $h1;
    $h1 = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "psgi streaming: test error: $msg";
            $cv->end;
        },
    );

    my $body = 'Hello PSGI world!';
    $h1->push_write(
        "POST /test HTTP/1.1$CRLF" .
        "Host: localhost$CRLF" .
        "X-Test: streaming$CRLF" .
        "Content-Length: " . length($body) . "$CRLF" .
        "Expect: 100-continue$CRLF" .
        "$CRLF"
    );

    $h1->push_read(regex => qr/100 Continue.*?$CRLF$CRLF/s, sub {
        my ($h, $data) = @_;
        like $data, qr/100 Continue/, 'psgi: got 100 Continue';

        $h->push_write($body);

        $h->push_read(regex => qr/$CRLF$CRLF/, sub {
            my ($h, $headers) = @_;
            like $headers, qr/200 OK/, 'psgi: got 200 response';

            $h->push_read(regex => qr/0\r\n\r\n/, sub {
                my ($h, $data) = @_;
                like $data, qr/PSGI: Hello PSGI world!/, 'psgi: body echoed correctly';
                $cv->end;
                $h->destroy;
                undef $h1;
            });
        });
    });

    $cv->recv;

    # Test psgix.io return with keepalive
    $cv = AE::cv;
    $cv->begin;

    my $h2;
    $h2 = AnyEvent::Handle->new(
        connect => ['127.0.0.1', $port],
        timeout => 3 * TIMEOUT_MULT,
        on_error => sub {
            my ($h, $fatal, $msg) = @_;
            fail "psgi psgix: test error: $msg";
            $cv->end;
        },
    );

    $h2->push_write(
        "GET /psgix HTTP/1.1$CRLF" .
        "Host: localhost$CRLF" .
        "X-Test: psgix-return$CRLF" .
        "Connection: keep-alive$CRLF" .
        "$CRLF" .
        "SECRET"
    );

    $h2->push_read(regex => qr/$CRLF$CRLF/, sub {
        my ($h, $data) = @_;
        like $data, qr/200 OK/, 'psgi: psgix-return got 200';

        $h->push_read(chunk => 2, sub {
            my ($h, $body) = @_;
            is $body, 'OK', 'psgi: psgix-return got OK body';

            $h->push_write(
                "GET /keepalive HTTP/1.1$CRLF" .
                "Host: localhost$CRLF" .
                "X-Test: keepalive-after$CRLF" .
                "Connection: close$CRLF" .
                "$CRLF"
            );

            $h->push_read(regex => qr/$CRLF$CRLF/, sub {
                my ($h, $data) = @_;
                like $data, qr/200 OK/, 'psgi: keepalive-after got 200';

                $h->push_read(chunk => 9, sub {
                    my ($h, $body) = @_;
                    is $body, 'KEEPALIVE', 'psgi: keepalive-after got body';
                    $cv->end;
                    $h->destroy;
                    undef $h2;
                });
            });
        });
    });

    $cv->recv;
    pass "psgi: all tests complete";
}

pass "all done";
