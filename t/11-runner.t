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

use Test::TCP;

my $feersum_script;
for my $dir (qw(blib/script blib/bin)) {
    if (-f "$dir/feersum") {
        $feersum_script = "$dir/feersum";
        last;
    }
}

plan skip_all => "can't locate feersum starter script"
    unless $feersum_script;

plan tests => 15;

ok -f 'eg/app.feersum' && -r _, "found eg/app.feersum";
ok -f 'eg/chat.feersum' && -r _, "found eg/chat.feersum";

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
                like $body, qr/^Hello customer number 0x[0-9a-f]+$/;
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
                like $body, qr/^Hello customer number 0x[0-9a-f]+$/;
                $cv->end;
            };
        $cv->recv;
    },
    server => sub {
        my $port = shift;
        exec "$^X -Mblib $feersum_script --listen localhost:$port ".
            "--native eg/app.feersum";
   },
);

SKIP: {
    skip "can't locate JSON::XS", 3
        unless eval "require JSON::XS";

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
            exec "$^X -Mblib $feersum_script --listen localhost:$port ".
                "--native eg/chat.feersum";
       },
    );
}
