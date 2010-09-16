#!perl
use warnings;
use strict;
use constant CLIENTS => 15;
use Test::More tests => 4 + 5*CLIENTS;
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
            ['Hello ','World']
        ];
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' || diag $@;
$evh->psgi_request_handler($app);

my $cv = AE::cv;

for my $n (1 .. CLIENTS) {
    $cv->begin;
    my $h; $h = simple_client GET => '/',
        name => "($n)",
    sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "($n) Response OK";
        is $headers->{'content-type'}, 'text/plain', "... ($n) is text";
        is $body, 'Hello World', "... ($n) correct body";
        $cv->end;
        undef $h;
    };
}

$cv->recv;
pass "all done";
