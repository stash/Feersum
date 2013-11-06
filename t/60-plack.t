#!perl
use strict;
use Test::More;
use blib;
BEGIN {
    $Plack::Test::Impl = 'Server';
    $ENV{PLACK_SERVER} = 'Feersum';
    $ENV{PLACK_ENV} = 'development';

    plan skip_all => "Need Plack >= 0.9950 to run this test"
        unless eval 'require Plack; $Plack::VERSION >= 0.995';
}

use Plack::Test;
use Plack::Loader;

plan tests => 7;

is(Plack::Loader->guess(), 'Feersum', "guess feersum");

loader_load: {
    my $svr = Plack::Loader->load('Feersum');
    isa_ok $svr, 'Plack::Handler::Feersum', "explicit load";
}

loader_auto: {
    my $svr = Plack::Loader->auto(host => 'ignored', port => '654321');
    isa_ok $svr, 'Plack::Handler::Feersum', "auto-load";
}

test_psgi(
    app => sub {
        my $env = shift;
        ok $env->{'psgix.body.scalar_refs'}, "seems to be Feersum";
        is_deeply $env->{'psgi.version'}, [1,1], "is PSGI 1.1";
        return [ 200, [ 'Content-Type' => 'text/plain' ], [ "Hello World" ] ],
    },
    client => sub {
        my $cb = shift;
        my $req = HTTP::Request->new(GET => "http://localhost/hello");
        my $res = $cb->($req);
        like $res->content, qr/Hello World/, "hello!";
    }
);

pass 'done';
