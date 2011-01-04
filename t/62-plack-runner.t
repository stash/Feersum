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

plan tests => 10;
use Test::TCP;
use File::Spec ();
use Config;

my $eg = File::Spec->catfile('eg','app.psgi');
my $eg_feersum = File::Spec->catfile('eg','app.feersum');

my $plackup = File::Spec->catfile($Config{sitescriptexp}, "plackup");
ok -e $plackup, 'found plackup';

sub run_client {
    my ($name, $port) = @_;
    my $cv = AE::cv;
    $cv->begin;
    my $cli = simple_client GET => '/',
        port => $port,
        name => $name,
        sub {
            my ($body,$headers) = @_;
            is $headers->{Status}, 200, "script http success";
            like $body, qr/^Hello customer number 0x[0-9a-f]+$/;
            $cv->end;
        };
    $cv->recv;
}

test_tcp(
    client => sub { run_client('feersum psgi runner',shift) },
    server => sub {
        my $port = shift;
        exec $^X, '-Mblib',
            File::Spec->catfile('blib','script','feersum'),
            '--listen' => "localhost:$port",
            $eg;
   },
);

test_tcp(
    client => sub { run_client('plackup psgi runner',shift) },
    server => sub {
        my $port = shift;
        exec $^X, '-Mblib', $plackup,
            '-E' => 'deployment',
            '-s' => 'Feersum',
            '--listen' => "localhost:$port",
            $eg;
   },
);

test_tcp(
    client => sub { run_client('feersum native runner',shift) },
    server => sub {
        my $port = shift;
        exec $^X, '-Mblib',
            File::Spec->catfile('blib','script','feersum'),
            '--native',
            '--listen' => "localhost:$port",
            $eg_feersum;
   },
);
