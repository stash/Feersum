#!/usr/bin/perl

# Ensure pod coverage in your distribution
use strict;
BEGIN {
	$|  = 1;
	$^W = 1;
}

my @MODULES = (
	'Test::Pod::Coverage 1.08',
        'File::Spec',
);

# Don't run tests during end-user installs
use Test::More;
plan( skip_all => 'Author tests not required for installation' )
	unless ( $ENV{RELEASE_TESTING} );

# Load the testing modules
foreach my $MODULE ( @MODULES ) {
	eval "use $MODULE";
	if ( $@ ) {
		$ENV{RELEASE_TESTING}
		? die( "Failed to load required release-testing module $MODULE" )
		: plan( skip_all => "$MODULE not available for testing" );
	}
}

my %poded = (
    'Feersum::Connection::Handle' => {
        pod_from => 'blib/lib/Feersum/Connection/Handle.pm',
    },
    'Feersum::Connection::Writer' => {
        pod_from => 'blib/lib/Feersum/Connection/Handle.pm',
    },
    'Feersum::Connection::Reader' => {
        pod_from => 'blib/lib/Feersum/Connection/Handle.pm',
    },
    'Feersum::Connection' => {
        pod_from => 'blib/lib/Feersum/Connection.pm',
    },
    'Feersum::Runner' => {
        pod_from => 'blib/lib/Feersum/Runner.pm',
    },
    'Feersum' => {
        pod_from => 'blib/lib/Feersum.pm',
    },
    'Plack::Handler::Feersum' => {
        pod_from => 'blib/lib/Plack/Handler/Feersum.pm',
    },
    'feersum' => {
        pod_from => 'blib/script/feersum',
    },
);
plan tests => scalar keys %poded;
while (my ($mod, $params) = each %poded) {
    $params->{pod_from} = File::Spec->catfile(split('/',$params->{pod_from}));
    pod_coverage_ok($mod, $params);
}

1;
