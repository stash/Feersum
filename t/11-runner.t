#!perl
use warnings;
use strict;
use Test::More;
use utf8;
use lib 't'; use Utils;

BEGIN { 
    plan skip_all => "Need Test::TCP 1.06 to run this test"
        unless eval 'require Test::TCP; $Test::TCP::VERSION >= 1.06';
}

plan tests => 13;
use Test::TCP;

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv;
        $cv->begin;
        my $cli = simple_client GET => '/',
            port => $port,
            name => 'manual runner',
            sub {
                my ($body,$headers) = @_;
                is $headers->{Status}, 200, "http success";
                like $body, qr/^Hello customer number \d+$/;
                $cv->end;
            };
        $cv->recv;
    },
    server => sub {
        use_ok 'Feersum::Runner';
        my $port = shift;

        my $runner;
        eval {
            my $app = do 'eg/app.feersum';
            ok $app, "did the app";
            $runner = Feersum::Runner->new(
                listen => ["localhost:$port"],
                app => $app
            );
            ok $runner, "got a runner";
        };
        warn $@ if $@;
        eval {
            ok $runner->{app}, "still got the app";
            $runner->run();
        };
        warn $@ if $@;
   },
);

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv;
        $cv->begin;
        my $cli = simple_client GET => '/',
            port => $port,
            name => 'script runner',
            sub {
                my ($body,$headers) = @_;
                is $headers->{Status}, 200, "script http success";
                like $body, qr/^Hello customer number \d+$/;
                $cv->end;
            };
        $cv->recv;
    },
    server => sub {
        my $port = shift;
        exec "$^X -Mblib blib/script/feersum --listen localhost:$port ".
            "--native eg/app.feersum";
   },
);

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv;
        $cv->begin;
        my $cli = simple_client GET => '/',
            port => $port,
            name => 'chat runner',
            sub {
                my ($body,$headers) = @_;
                is $headers->{Status}, 200, "chat http success";
                like $body, qr{<title>Chat!</title>};
                $cv->end;
            };
        $cv->recv;
    },
    server => sub {
        my $port = shift;
        exec "$^X -Mblib blib/script/feersum --listen localhost:$port ".
            "--native eg/chat.feersum";
   },
);
