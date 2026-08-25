#!perl
# CRLF injection protection (CWE-113 response splitting)
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More tests => 18;
use lib 't'; use Utils;
use AnyEvent;
use AnyEvent::Handle;

require Feersum;

# Silence DIED messages: they're expected here
{ no warnings 'redefine', 'once'; *Feersum::DIED = sub { } }

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

my $current_handler;
$feer->request_handler(sub { $current_handler->(@_) });

sub raw_get {
    my ($path, $on_port) = @_;
    $on_port //= $port;
    my $cv = AE::cv;
    my $resp = '';
    my $h = AnyEvent::Handle->new(
        connect => ['localhost', $on_port],
        on_error => sub { $cv->send },
        on_eof   => sub { $cv->send },
    );
    $h->push_write("GET $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    $h->on_read(sub { $resp .= $_[0]->rbuf; $_[0]->rbuf = '' });
    my $t = AE::timer 2 * TIMEOUT_MULT, 0, sub { $cv->send };
    $cv->recv;
    return $resp;
}

# Each case: handler tries to inject CRLF, should croak -> 500
my $n = 0;
for my $case (
    ['CR in header value', '200 OK', ['X-Foo' => "bar\rX-Evil: 1"]],
    ['LF in header value', '200 OK', ['X-Foo' => "bar\nX-Evil: 1"]],
    ['CRLF in header value', '200 OK', ['X-Foo' => "bar\r\nX-Evil: 1"]],
    ['CR in header name',  '200 OK', ["X-Foo\rX-Evil" => 'bar']],
    ['LF in header name',  '200 OK', ["X-Foo\nX-Evil" => 'bar']],
    ['colon in header name', '200 OK', ["X-Foo:bad" => 'bar']],
    ['CR in status message', "200 OK\r\nX-Evil: 1", []],
    ['LF in status message', "200 OK\nX-Evil: 1", []],
) {
    my ($desc, $msg, $hdrs) = @$case;
    $current_handler = sub {
        my $r = shift;
        $r->send_response($msg, $hdrs, \"hello");
    };
    my $resp = raw_get("/case" . ++$n);
    like $resp, qr{^HTTP/1\.1 500}, "$desc: rejected with 500";
}

# Verify legitimate request still works after error path
$current_handler = sub {
    my $r = shift;
    $r->send_response(200, ['X-Foo' => 'normal value'], \"ok");
};
my $good = raw_get('/good');
like $good, qr{^HTTP/1\.1 200}, 'normal request still works after rejections';

# Sanity: no injected header on the wire from any failure case
$current_handler = sub {
    my $r = shift;
    $r->send_response('200 OK', ['X-Foo' => "bar\r\nX-Evil: pwn"], \"hello");
};
my $resp = raw_get('/splitcheck');
unlike $resp, qr{X-Evil}i, 'no smuggled header appeared on wire';

# Connection still healthy
$current_handler = sub {
    my $r = shift;
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"recovered");
};
my $after = raw_get('/after');
like $after, qr{^HTTP/1\.1 200.*recovered}s, 'server functional after CRLF rejection';

# PSGI path: croaks in feersum_start_response would crash the worker because
# the PSGI dispatcher is outside any G_EVAL frame. Pre-validation in the
# dispatcher must catch each case and route through call_died (= 500).
{
    my ($s2, $p2) = get_listen_socket();
    my $f2 = Feersum->new_instance();
    $f2->use_socket($s2);

    my $psgi_response;
    $f2->psgi_request_handler(sub { $psgi_response });

    # 1. CRLF in header value
    $psgi_response = [200, ['X-Foo' => "bar\r\nX-Evil: pwn"], ["body"]];
    my $r1 = raw_get('/crlf', $p2);
    like   $r1, qr{^HTTP/1\.1 500}, 'PSGI CRLF in header returns 500';
    unlike $r1, qr{X-Evil},         'PSGI CRLF: no smuggled header on wire';

    # 2. Bad status (non-numeric string)
    $psgi_response = ['OK', [], ['body']];
    my $r2 = raw_get('/badstatus', $p2);
    like $r2, qr{^HTTP/1\.1 500}, 'PSGI non-numeric status returns 500';

    # 3. Odd-length headers array
    $psgi_response = [200, ['X-Foo'], ['body']];
    my $r3 = raw_get('/oddhdr', $p2);
    like $r3, qr{^HTTP/1\.1 500}, 'PSGI odd-length headers returns 500';

    # 4. Worker alive after all bad-response paths
    $psgi_response = [200, ['Content-Type' => 'text/plain'], ['psgi-ok']];
    my $rok = raw_get('/ok', $p2);
    like $rok, qr{psgi-ok}, 'PSGI worker alive after bad-response rejections';

    # 5. Streaming PSGI: $respond->([200, [CRLF-injected]]) goes through
    # _continue_streaming_psgi -> feersum_start_response. That croak is
    # caught by the G_EVAL frame wrapping _initiate_streaming_psgi, so the
    # worker stays alive and a 500 is sent. Verify both.
    $f2->psgi_request_handler(sub {
        return sub {
            my $respond = shift;
            $respond->([200, ['X-Foo' => "bar\r\nX-Evil: pwn"]]);
        };
    });
    my $rs = raw_get('/stream-crlf', $p2);
    like $rs, qr{^HTTP/1\.1 500}, 'PSGI streaming CRLF in headers returns 500';
}
