#!perl
# Extended memory leak tests for new features (priority API)
use warnings;
use strict;
use blib;
use Test::More;

BEGIN {
    if (eval q{
        require Test::LeakTrace; $Test::LeakTrace::VERSION >= 0.13
    }) {
        plan tests => 4;
    }
    else {
        plan skip_all => "Need Test::LeakTrace >= 0.13 to run this test"
    }
}

use Test::LeakTrace;
BEGIN { use_ok('Feersum') };

my $evh = Feersum->new();
ok $evh, "got Feersum instance";

# Test priority API doesn't leak
leaks_cmp_ok {
    for (1..1000) {
        $evh->read_priority(2);
        $evh->read_priority(-2);
        $evh->read_priority(0);
        $evh->write_priority(2);
        $evh->write_priority(-2);
        $evh->write_priority(0);
        $evh->accept_priority(2);
        $evh->accept_priority(-2);
        $evh->accept_priority(0);
    }
} '<=', 0, 'priority API does not leak';

# Test read_timeout API doesn't leak (existing feature, sanity check)
leaks_cmp_ok {
    for (1..1000) {
        my $old = $evh->read_timeout;
        $evh->read_timeout(30);
        $evh->read_timeout(60);
        $evh->read_timeout($old);
    }
} '<=', 0, 'read_timeout API does not leak';
