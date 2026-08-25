#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN {
    plan skip_all => 'not applicable on win32'
        if $^O eq 'MSWin32';
}

plan tests => 8;

use_ok('Feersum::Runner');

my $app = sub { [200, ['Content-Type' => 'text/plain'], ['hello']] };

#######################################################################
# Test 1: Runner->new accepts multiple listen addresses (array)
#######################################################################

{
    my $runner;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0', 'localhost:0'],
            quiet  => 1,
            app    => $app,
        );
    };
    ok(!$@, 'Runner->new with multiple listen addresses does not croak')
        or diag "Error: $@";
    ok($runner, 'Runner object created successfully');
    is(ref $runner->{listen}, 'ARRAY', 'listen param stored as arrayref');
    is(scalar @{$runner->{listen}}, 2, 'listen array has 2 entries');
    undef $Feersum::Runner::INSTANCE;
}

#######################################################################
# Test 2: _prepare() creates multiple sockets
#######################################################################

{
    my $runner;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0', 'localhost:0'],
            quiet  => 1,
            app    => $app,
        );
        $runner->_prepare();
    };
    ok(!$@, '_prepare() with multiple listen addresses succeeds')
        or diag "Error: $@";

    my $socks = $runner->{_socks} || [];
    is(scalar @$socks, 2, '_prepare() created 2 sockets');

    # Verify each socket got a valid OS-assigned port
    my $all_valid = 1;
    for my $sock (@$socks) {
        unless (defined $sock && defined fileno($sock)) {
            $all_valid = 0;
            last;
        }
    }
    ok($all_valid, 'all sockets have valid file descriptors');

    undef $Feersum::Runner::INSTANCE;
}
