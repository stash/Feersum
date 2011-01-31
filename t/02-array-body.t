#!perl
use warnings;
use strict;
use Test::More tests => 12;
use Test::Fatal;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';
    is exception {
        $r->send_response("200 OK", [
            'Content-Type' => 'text/plain; charset=UTF-8',
            'Connection' => 'close',
        ], ['this ',\'should ',undef,'be ','cøncātenated.']);
    }, undef, 'sent response';
});

is exception {
    $evh->use_socket($socket);
}, undef, 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = simple_client GET => '/?blar',
    timeout => 3,
    sub {
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
