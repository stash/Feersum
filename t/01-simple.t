#!perl
use warnings;
use strict;
use Test::More tests => 32;
use Test::Exception;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

dies_ok {
    $evh->request_handler('foo');
} "can't assign regular scalar";

my $cb;
{
    my $g = guard { pass "cv recycled"; };
    $cb = sub { $g = $g; fail "old callback" };
}

lives_ok {
    $evh->request_handler($cb);
} "can assign code block";

undef $cb;
pass "after undef cb";

$cb = sub {
    pass "called back!";
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';
#     use Devel::Peek();
#     Devel::Peek::Dump($r);
    my $env = $r->env();
    ok $env, "got env";
    is $env->{HTTP_USER_AGENT}, 'FeersumSimpleClient/1.0', 'got a ua!';
    my $utf8 = exists $env->{HTTP_X_UNICODE_PLEASE};
    eval {
        $r->send_response("200 OK", [
            'Content-Type' => 'text/plain'.($utf8 ? '; charset=UTF-8' : ''),
            'Connection' => 'close',
            'X-Client' => 1234,
            'Content-Length' => 666, # should be ignored
        ], $utf8 ? 'Bāz!' : 'Baz!');
    }; warn $@ if $@;
    pass "done request handler";
};

lives_ok {
    $evh->request_handler($cb);
} "can assign another code block";

my $cv = AE::cv;
$cv->begin;

my $w = simple_client GET => '/?qqqqq',
    name => 'ascii',
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client 1 got 200";
        like $hdr->{'x-client'}, qr/^\d+$/, 'got a custom x-client header';
        is $hdr->{'content-length'}, 4, 'content-length was overwritten by the engine';
        is $hdr->{'content-type'}, 'text/plain';
        is $body, 'Baz!', 'plain old body';
        $cv->end;
    };

$cv->begin;
my $w2 = simple_client GET => "/?zzzzz",
    name => 'unicode',
    headers => { 'X-Unicode-Please' => 1 },
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client 2 got 200";
        like $hdr->{'x-client'}, qr/^\d+$/, 'got a custom x-client header';
        is $hdr->{'content-length'}, 5, 'content-length was overwritten by the engine';
        is $hdr->{'content-type'}, 'text/plain; charset=UTF-8';
        is Encode::decode_utf8($body), 'Bāz!', 'unicode body!';
        $cv->end;
    };

$cv->recv;
pass "all done";
