#!perl
use warnings;
use strict;
use Test::More qw/no_plan/;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();
{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        fail "Died during request handler: $err";
    };
}
$evh->use_socket($socket);

my $APP = <<'EOAPP';
    my $app = sub {
        my $env = shift;
        Test::More::ok $env, "got an env in callback";
        return [
            200,
            ['Content-Type' => 'text/plain'],
            ['Hello World']
        ];
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' || diag $@;
$evh->psgi_request_handler($app);

use AnyEvent::HTTP;
my $cv = AE::cv;

my $r = http_get "http://localhost:$port/", timeout => 300, sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "Response OK";
    is $headers->{'content-type'}, 'text/plain', "... is text";
    is $body, 'Hello World', '... correct body';
    pass 'done client';
    $cv->send;
};
ok $r, 'started http request';
$cv->recv;
pass "all done";
