#!perl
use warnings;
use strict;
use Test::More tests => 11;
use Test::Exception;
use blib;
use Carp ();
use Encode;
use utf8;
use bytes; no bytes;
$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

BEGIN { use_ok('Socialtext::EvHttp') };

use IO::Socket::INET;
use AnyEvent;
use AnyEvent::HTTP;

my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10203',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
);
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Socialtext::EvHttp->new();

$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Socialtext::EvHttp::Client', 'got an object!';
    lives_ok {
        $r->send_response("200 OK", [
            'Content-Type' => 'text/plain; charset=UTF-8',
            'Connection' => 'close',
        ], ['this ','should ',undef,'be ','cøncātenated.']);
    } 'sent response';
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = http_get 'http://localhost:10203/?blar', timeout => 3, sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client got 200";
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';

    $body = Encode::decode_utf8($body) unless Encode::is_utf8($body);

    is $headers->{'content-length'}, bytes::length($body),
        'content-length was calculated correctly';

    is $body, 'this should be cøncātenated.',
        'body was concatenated together';
    $cv->end;
};

$cv->recv;
pass "all done";
