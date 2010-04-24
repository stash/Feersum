use 5.008007;
use ExtUtils::MakeMaker;
use EV::MakeMaker qw/ev_args/;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(ev_args(
    NAME              => 'Socialtext::EvHttp',
    VERSION_FROM      => 'lib/Socialtext/EvHttp.pm', # finds $VERSION
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Socialtext/EvHttp.pm', # retrieve abstract from module
       AUTHOR         => 'Jeremy Stashewsky <jstash@cpan.org>') : ()),
    LIBS              => [''], # e.g., '-lm'
    DEFINE            => '', # e.g., '-DHAVE_SOMETHING'
    INC               => '-I.', # e.g., '-I. -I/usr/include/other'
	# Un-comment this if you add C files to link with later:
    # OBJECT            => '$(O_FILES)', # link all the C files too
));
