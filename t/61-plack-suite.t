#!perl
use warnings;
use strict;
use blib;
use Test::More;

BEGIN { 
    plan skip_all => "Need Plack >= 0.9950 to run this test"
        unless eval 'require Plack; $Plack::VERSION >= 0.995';
}
use Feersum;

{
    no warnings 'redefine';
    *Feersum::DIED = sub { diag "Feersum caught: ",@_ };
}

use Plack::Test::Suite;

Plack::Test::Suite->run_server_tests('Feersum');
done_testing;
