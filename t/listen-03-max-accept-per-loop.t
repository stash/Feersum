#!perl
# Test max_accept_per_loop() getter/setter API.
use strict;
use warnings;
use Test::More tests => 10;
use blib;

use Feersum;

# 1. Singleton default is 64
my $evh = Feersum->new();
is $evh->max_accept_per_loop(), 64, "singleton default is 64";

# 2. Set a positive value and read it back
$evh->max_accept_per_loop(10);
is $evh->max_accept_per_loop(), 10, "set to 10, getter returns 10";

# 3. Setting 0 is floored to 1 at XS level
$evh->max_accept_per_loop(0);
is $evh->max_accept_per_loop(), 1, "setting 0 floors to 1";

# 4. Setting a negative value is floored to 1
$evh->max_accept_per_loop(-5);
is $evh->max_accept_per_loop(), 1, "setting -5 floors to 1";

# 5. Setting 1 works (minimum valid value)
$evh->max_accept_per_loop(1);
is $evh->max_accept_per_loop(), 1, "setting 1 works";

# 6. Large value works
$evh->max_accept_per_loop(1000);
is $evh->max_accept_per_loop(), 1000, "setting 1000 works";

# 7. new_instance() gets default 64
my $inst = Feersum->new_instance();
is $inst->max_accept_per_loop(), 64, "new_instance() default is 64";

# 8. Changing instance doesn't affect singleton
$inst->max_accept_per_loop(5);
is $evh->max_accept_per_loop(), 1000, "instance change doesn't affect singleton";

# 9. endjinn() is an alias for new() (glob alias)
my $via_endjinn = Feersum->endjinn();
is ref($via_endjinn), 'Feersum', "endjinn() returns a Feersum object";

# 10. endjinn() returns the same singleton as new()
is $via_endjinn, Feersum->new(), "endjinn() returns same singleton as new()";
