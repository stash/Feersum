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
for my $key (qw(bin scriptdir sitebin sitescript vendbin vendscript)) {
    my $dir = $Config{$key.'exp'};
    next unless $dir;

    my $pu = "$dir/plackup";
    next unless (-e $pu && -x _);

    my $plackup_ver = `$^X $pu --version`;
    next unless ($plackup_ver =~ /Plack (\d.\d+)/ && $1 >= 0.995);

    $plackup = $pu;
    chomp $plackup_ver;
    diag "found plackup: $plackup ($plackup_ver)";
    last;
}

SKIP: {
    skip "can't locate plackup in script/bin dirs", 3
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
