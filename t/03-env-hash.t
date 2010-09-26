#!perl
use warnings;
use strict;
use Test::More tests => 106;
use Test::Exception;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket, $port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        warn "Died during request handler: $err";
    };
}

$evh->request_handler(sub {
    local $@;
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'connection';
    my $env;
    lives_ok { $env = $r->env() } 'obtain env';
    ok $env && ref($env) eq 'HASH', "env hash";

    my $tn = $env->{HTTP_X_TEST_NUM} || 0;
    ok $tn, "got a test number header $tn";

    is_deeply $env->{'psgi.version'}, [1,0], 'got psgi.version';
    is $env->{'psgi.url_scheme'}, "http", 'got psgi.url_scheme';
    ok $env->{'psgi.nonblocking'}, 'got psgi.nonblocking';
    is $env->{'psgi.multithread'}, '', 'got psgi.multithread';
    is $env->{'psgi.multiprocess'}, '', 'got psgi.multiprocess';
    ok $env->{'psgix.body.scalar_refs'}, 'Feersum supports scalar-refs in the body part of the response (psgix.body.scalar_refs)';

    my $errfh = $env->{'psgi.errors'};
    ok $errfh, 'got psgi.errors';
    lives_ok { $errfh->print() } "errors fh can print()";

    is $env->{REQUEST_METHOD}, 'GET', "got req method";
    like $env->{HTTP_USER_AGENT}, qr/FeersumSimpleClient/, "got UA";

    is $env->{CONTENT_LENGTH}, 0, "got zero C-L";
    ok !exists $env->{HTTP_CONTENT_LENGTH}, "no duplicate C-L header";

    if ($tn == 1) {
        like $env->{HTTP_REFERER}, qr/wrong/, "got the Referer";
        is $env->{QUERY_STRING}, 'blar', "got query string";
        is $env->{PATH_INFO}, '/what is wrong?', "got decoded path info string";
        is $env->{REQUEST_URI}, '/what%20is%20wrong%3f?blar', "got full URI string";
    }
    elsif ($tn == 2) {
        like $env->{HTTP_REFERER}, qr/good/, "got a Referer";
        is $env->{QUERY_STRING}, 'dlux=sonice', "got query string";
        is $env->{PATH_INFO}, '/what% is good?%2', "got decoded path info string";
        is $env->{REQUEST_URI}, '/what%%20is%20good%3F%2?dlux=sonice', "got full URI string";
    }
    elsif ($tn == 3) {
        like $env->{HTTP_REFERER}, qr/ugly/, "got a Referer";
        is $env->{QUERY_STRING}, '', "got query string";
        is $env->{PATH_INFO}, '/no query', "got decoded path info string";
        is $env->{REQUEST_URI}, '/no%20query', "got full URI string";
    }

    is $env->{SERVER_NAME}, '127.0.0.1', "got server name";
    is $env->{SERVER_PORT}, $port, "got server port";
    ok $env->{REMOTE_ADDR}, "remote addr";
    ok $env->{REMOTE_PORT}, "remote port";

    ok !exists $env->{HTTP_ACCEPT_CHARSET},
        "spot check that a placeholder Accept-Charset isn't there";
    ok !exists $env->{HTTP_ACCEPT_LANGUAGE},
        "spot check that a placeholder Accept-Language isn't there";

    lives_ok {
        $r->send_response("200 OK", [
            'Content-Type' => 'text/plain; charset=UTF-8',
            'Connection' => 'close',
        ], ["Oh Hai $env->{HTTP_X_TEST_NUM}\n"]);
    } 'sent response';
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = simple_client GET => "/what%20is%20wrong%3f?blar",
    headers => {'x-test-num' => 1, 'Referer' => '/wrong'},
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client 1 got 200";
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';

    $body = Encode::decode_utf8($body) unless Encode::is_utf8($body);

    is $headers->{'content-length'}, bytes::length($body),
        'client 1 content-length was calculated correctly';

    is $body, "Oh Hai 1\n", 'client 1 expected body';
    $cv->end;
};

$cv->begin;
my $w2 = simple_client GET => "/what%%20is%20good%3F%2?dlux=sonice", 
    headers => {'x-test-num' => 2, 'Referer' => 'good'},
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client 2 got 200";
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';

    $body = Encode::decode_utf8($body) unless Encode::is_utf8($body);

    is $headers->{'content-length'}, bytes::length($body),
        'client 2 content-length was calculated correctly';

    is $body, "Oh Hai 2\n", 'client 2 expected body';
    $cv->end;
};

$cv->begin;
my $w3 = simple_client GET => "/no%20query",
    headers => {'x-test-num' => 3, 'Referer' => 'ugly'},
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client 3 got 200";
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';

    $body = Encode::decode_utf8($body) unless Encode::is_utf8($body);

    is $headers->{'content-length'}, bytes::length($body),
        'client 3 content-length was calculated correctly';

    is $body, "Oh Hai 3\n", 'client 3 expected body';
    $cv->end;
};

$cv->begin;
my $w4 = simple_client GET => "/no spaces allowed",
    headers => {'x-test-num' => 4, 'Referer' => 'ugly'},
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 400, 'client 4 Bad Request';
    is $headers->{Reason}, "Bad Request";
    is $headers->{'content-type'}, 'text/plain';
    is $body, "Malformed request.\n", 'client 4 expected error';
    $cv->end;
};

$cv->recv;
pass "all done";
