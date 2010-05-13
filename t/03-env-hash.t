#!perl
use warnings;
use strict;
use Test::More tests => 51;
use Test::Exception;
use utf8;
use lib 't'; use Utils;
use Scalar::Util qw/blessed/;

BEGIN { use_ok('Feersum') };

use AnyEvent::HTTP;

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
    my $r = shift;
    isa_ok $r, 'Feersum::Client', 'got an object!';
    ok ($r->fileno && !blessed($r->fileno));
    my $env = {};
    $r->env($env);
    ok $env && ref($env) eq 'HASH';

    is_deeply $env->{'psgi.version'}, [1,0], 'got psgi.version';
    is $env->{'psgi.url_scheme'}, "http", 'got psgi.url_scheme';
    ok $env->{'psgi.nonblocking'}, 'got psgi.nonblocking';
    ok $env->{'psgi.multithreaded'}, 'got psgi.multithreaded';
    my $errfh = $env->{'psgi.errors'};
    ok $errfh, 'got psgi.errors';
    lives_ok {
        $errfh->print("# foo!\n");
    } "errors fh can print()";

    is $env->{REQUEST_METHOD}, 'GET', "got req method";
    like $env->{HTTP_USER_AGENT}, qr/AnyEvent-HTTP/, "got UA";

    is $env->{CONTENT_LENGTH}, 0, "got zero C-L";
    ok !exists $env->{HTTP_CONTENT_LENGTH}, "no duplicate C-L header";

    ok $env->{HTTP_X_TEST_NUM}, "got a test number header";
    if ($env->{HTTP_X_TEST_NUM} == 1) {
        like $env->{HTTP_REFERER}, qr/wrong/, "got the AE Referer";
        is $env->{QUERY_STRING}, 'blar', "got query string";
        is $env->{PATH_INFO}, '/what is wrong?', "got decoded path info string";
        is $env->{REQUEST_URI}, '/what%20is%20wrong%3f?blar', "got full URI string";
    }
    else {
        like $env->{HTTP_REFERER}, qr/good/, "got the AE Referer";
        is $env->{QUERY_STRING}, 'dlux=sonice', "got query string";
        is $env->{PATH_INFO}, '/what% is good?%2', "got decoded path info string";
        is $env->{REQUEST_URI}, '/what%%20is%20good%3F%2?dlux=sonice', "got full URI string";
    }

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
my $w = http_get "http://localhost:$port/what%20is%20wrong%3f?blar",
    headers => {'x-test-num' => 1},
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client got 200";
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';

    $body = Encode::decode_utf8($body) unless Encode::is_utf8($body);

    is $headers->{'content-length'}, bytes::length($body),
        'content-length was calculated correctly';

    is $body, "Oh Hai 1\n", 'got expected body';
    $cv->end;
};

$cv->begin;
my $w2 = http_get "http://localhost:$port/what%%20is%20good%3F%2?dlux=sonice", 
    headers => {'x-test-num' => 2},
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client got 200";
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';

    $body = Encode::decode_utf8($body) unless Encode::is_utf8($body);

    is $headers->{'content-length'}, bytes::length($body),
        'content-length was calculated correctly';

    is $body, "Oh Hai 2\n", 'got expected body';
    $cv->end;
};

$cv->recv;
pass "all done";
