#!perl
use warnings;
use strict;
use Test::More tests => 21;
use Test::Exception;
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
    my $env = $r->env;
    ok $env, 'got env';
    lives_ok {
        if ($env->{HTTP_X_CLIENT} == 1) {
            $r->send_response("304", [], []); # explicit string, not num
        }
        else {
            $r->send_response("304 Not Modified", ['Content-Length'=>123], []);
        }
    } 'sent response for '.$env->{HTTP_X_CLIENT};
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = simple_client GET => '/?blef',
    headers => { 'X-Client' => 1 },
    timeout => 3,
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 304, "client got 304";
        ok !exists $headers->{'content-type'}, 'missing c-t';
        # 304 not-modifieds shouldn't auto-generate a content-length header or
        # any other "entity" headers.  These reflect the actual entity, and
        # can update cache's respresentation of the object.
        ok !exists $headers->{'content-length'},'no c-l generated';
        ok !$body, 'no body';
        $cv->end;
    };

$cv->begin;
my $w2 = simple_client GET => '/?blef',
    headers => { 'X-Client' => 2 },
    timeout => 3,
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 304, "2nd client got 304";
        ok !exists $headers->{'content-type'}, 'missing c-t';
        # If the app specified a C-L, we should respect it for the same
        # reasons.
        is $headers->{'content-length'}, 123, 'c-l not replaced';
        ok !$body, 'no body';
        $cv->end;
    };

$cv->recv;
pass "all done";
