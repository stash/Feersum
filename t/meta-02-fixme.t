#!/usr/bin/perl

# Check source files for 'FIX'.'ME' statements
use strict;
BEGIN {
	$|  = 1;
	$^W = 1;
}

my @MODULES = (
	'Test::Fixme 0.04',
);

# Don't run tests during end-user installs
use Test::More;
plan( skip_all => 'Author tests not required for installation' )
	unless ( $ENV{RELEASE_TESTING} or $ENV{AUTOMATED_TESTING} );

# Load the testing modules
foreach my $MODULE ( @MODULES ) {
	eval "use $MODULE";
	if ( $@ ) {
		$ENV{RELEASE_TESTING}
		? die( "Failed to load required release-testing module $MODULE" )
		: plan( skip_all => "$MODULE not available for testing" );
	}
}

run_tests(
    where => [qw(lib bin eg t xt),
              glob('feersum_*.c.inc feersum_*.h *.xs rinq.c')],
    match => qr/[T]ODO|[F]IXME|[X]XX/,
    # Scan hand-written source only. Keep the extensionless bin/feersum script,
    # .feersum examples, and the root C/XS/inc/header implementation. Skip
    # generated/compiled artifacts: the xsubpp-generated Feersum.c (excluded
    # from `where` - only rinq.c is globbed, not *.c) and eg/ sub-dist
    # .c/.o/.so/.bs/Makefile (never match the extension list).
    filename_match =>
        qr/\.(?:pm|pl|pod|psgi|t|xs|PL|c\.inc)$|feersum_\w+\.h$|(?:^|\/)rinq\.c$|feersum$/i,
);

1;
