#!perl
use warnings;
use strict;
use blib;
use Test::More tests => 18;

BEGIN { use_ok('Feersum') };
BEGIN { use_ok('EV') };

my $evh = Feersum->new();
ok $evh, "got Feersum singleton";

# Test default values
is $evh->read_priority, 0, "default read_priority is 0";
is $evh->write_priority, 0, "default write_priority is 0";
is $evh->accept_priority, 0, "default accept_priority is 0";

# Test setting valid values
is $evh->read_priority(2), 2, "set read_priority to max (2)";
is $evh->read_priority, 2, "read_priority persists";

is $evh->write_priority(-2), -2, "set write_priority to min (-2)";
is $evh->write_priority, -2, "write_priority persists";

is $evh->accept_priority(1), 1, "set accept_priority to 1";
is $evh->accept_priority, 1, "accept_priority persists";

# Test clamping to EV_MAXPRI (2)
is $evh->read_priority(100), 2, "read_priority clamped to max";
is $evh->write_priority(999), 2, "write_priority clamped to max";

# Test clamping to EV_MINPRI (-2)
is $evh->read_priority(-100), -2, "read_priority clamped to min";
is $evh->write_priority(-999), -2, "write_priority clamped to min";

# Reset to defaults for other tests
$evh->read_priority(0);
$evh->write_priority(0);
$evh->accept_priority(0);

is $evh->read_priority, 0, "read_priority reset to 0";
is $evh->write_priority, 0, "write_priority reset to 0";
