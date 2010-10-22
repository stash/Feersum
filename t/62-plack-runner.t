#!perl
use strict;
use Test::More;
use blib;
use lib 't'; use Utils;
BEGIN {
    plan skip_all => "Need Plack >= 0.9950 to run this test"
        unless eval 'require Plack; $Plack::VERSION >= 0.995';
    plan skip_all => "Need Test::TCP 1.06 to run this test"
        unless eval 'require Test::TCP; $Test::TCP::VERSION >= 1.06';
}

plan tests => 7;
use Test::TCP;

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv;
        $cv->begin;
        my $cli = simple_client GET => '/',
            port => $port,
            name => 'feersum runner',
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
        exec "$^X -Mblib blib/script/feersum --listen localhost:$port ".
            "eg/app.psgi";
   },
);

# XXX: ugh, what's a better cross-platform way of doing this?
my $plackup = `which plackup`;
chomp $plackup;
ok $plackup, 'found plackup';

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv;
        $cv->begin;
        my $cli = simple_client GET => '/',
            port => $port,
            name => 'plackup runner',
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
        exec "$^X -Mblib $plackup -E deployment ".
            "-s Feersum --listen localhost:$port eg/app.psgi";
   },
);
