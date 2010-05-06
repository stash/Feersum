use 5.008007;
use ExtUtils::MakeMaker;
use EV::MakeMaker qw/ev_args/;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(ev_args(
    NAME              => 'Feersum',
    VERSION_FROM      => 'lib/Feersum.pm',
    PREREQ_PM         => {
        'EV'    => 3.8,
        'Guard' => 1.012,
        # for testing
        'AnyEvent' => 0,
        'AnyEvent::HTTP' => 0,
        'Test::More' => 0,
        'Test::Differences' => 0,
        'Test::Exception' => 0,
    },
    ABSTRACT_FROM     => 'lib/Feersum.pm',
    AUTHOR            => 'Jeremy Stashewsky <jstash@cpan.org>',
    LIBS              => [''], # e.g., '-lm'
    DEFINE            => '', # e.g., '-DHAVE_SOMETHING'
    INC               => '-I.', # e.g., '-I. -I/usr/include/other'
	# Un-comment this if you add C files to link with later:
    # OBJECT            => '$(O_FILES)', # link all the C files too
));
