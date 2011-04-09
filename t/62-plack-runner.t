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

plan tests => 6;
use Test::TCP;
use Config;

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

my $plackup;
for my $dir (@Config{qw(sitebin sitescript vendbin vendscript)}) {
    my $pu = "$dir/plackup";
    if (-e $pu && -x _) {
        $plackup = $pu;
        my $plackup_ver = `$^X $plackup --version`;
        chomp $plackup_ver;
        if ($plackup_ver =~ /Plack (\d.\d+)/ && $1 >= 0.995) {
            diag "plackup: $plackup ($plackup_ver)";
        }
        else {
            next;
        }
        last;
    }
}

SKIP: {
    skip "can't locate plackup in sitebin/sitescript/vendbin/vendscript", 2
        unless $plackup;
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
}
