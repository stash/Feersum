#!perl
use warnings;
use strict;
use Test::More tests => 10;
use Test::Fatal;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

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

is exception {
    $evh->use_socket($socket);
}, undef, 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = simple_client GET => "/?blar", timeout => 3, sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 500, "client got 500";
    is $headers->{'content-type'}, 'text/plain';
    is $body, "Request handler exception.\n", 'got expected body';
    $cv->end;
};

$cv->recv;
pass "all done";
