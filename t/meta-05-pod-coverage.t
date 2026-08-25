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

# Feersum::Connection::{Reader,Writer} have no .pm file - the XS bootstrap
# creates the stashes - so Pod::Coverage's "require $package" would fail.
use Feersum ();
$INC{'Feersum/Connection/Reader.pm'} = $INC{'Feersum.pm'};
$INC{'Feersum/Connection/Writer.pm'} = $INC{'Feersum.pm'};

# HEADER_NORM_* are exported by Feersum but documented where they are used, in
# Feersum::Connection.  Handle::new is internal - handles come from the XS side.
my @norm_consts = (qr/^HEADER_NORM_/);

my %poded = (
    'Feersum::Connection::Handle' => {
        pod_from => 'blib/lib/Feersum/Connection/Handle.pm',
        also_private => ['new'],
    },
    'Feersum::Connection::Writer' => {
        pod_from => 'blib/lib/Feersum/Connection/Handle.pm',
        also_private => ['new'],
    },
    'Feersum::Connection::Reader' => {
        pod_from => 'blib/lib/Feersum/Connection/Handle.pm',
        also_private => ['new'],
    },
    'Feersum::Connection' => {
        pod_from => 'blib/lib/Feersum/Connection.pm',
    },
    'Feersum::Runner' => {
        pod_from => 'blib/lib/Feersum/Runner.pm',
    },
    'Feersum' => {
        pod_from => 'blib/lib/Feersum.pm',
        also_private => \@norm_consts,
    },
    'Plack::Handler::Feersum' => {
        pod_from => 'blib/lib/Plack/Handler/Feersum.pm',
    },
    # bin/feersum is a script, not a module: it cannot be require'd, and
    # t/meta-04-pod.t already checks its POD is well-formed.
);
plan tests => scalar keys %poded;
while (my ($mod, $params) = each %poded) {
    $params->{pod_from} = File::Spec->catfile(split('/',$params->{pod_from}));
    pod_coverage_ok($mod, $params);
}

1;
