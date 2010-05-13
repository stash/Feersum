#!perl
use warnings;
use strict;
use Test::More tests => 9;
use Test::Exception;
use Scalar::Util qw/blessed/;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

use AnyEvent::HTTP;

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        like $err, qr/holy crap/, 'DIED was called';
    };
}

$evh->request_handler(sub {
    my $r = shift;
    die "holy crap!";
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = http_get "http://localhost:$port/?blar", timeout => 3, sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 500, "client got 500";
    is $headers->{'content-type'}, 'text/plain';
    is $body, "Request handler exception.\n", 'got expected body';
    $cv->end;
};

$cv->recv;
pass "all done";
