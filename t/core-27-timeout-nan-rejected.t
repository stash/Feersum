#!perl
# Timeout setters reject NaN like read_timeout does; 0 still disables and
# negatives still croak on the setters that document "non-negative".
use warnings;
use strict;
use Test::More tests => 14;
use Feersum;

my $inf = 9**9**9;
my $nan = $inf - $inf;
ok $nan != $nan, "test setup really made a NaN"
    or diag "inf=$inf nan=$nan";

my $f = Feersum->new_instance;

eval { $f->read_timeout($nan) };
like $@, qr/positive/, "read_timeout(NaN) croaks (control)";

for my $setter (qw(header_timeout write_timeout linger_timeout)) {
    eval { $f->$setter($nan) };
    like $@, qr/non-negative/, "$setter(NaN) croaks";

    eval { $f->$setter(-1) };
    like $@, qr/non-negative/, "$setter(-1) still croaks";

    ok eval { $f->$setter(0); 1 }, "$setter(0) disables";
    is eval { $f->$setter(0); $f->$setter() }, 0, "$setter(0) reads back 0";
}
