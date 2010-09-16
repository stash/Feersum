use 5.008007;
use ExtUtils::MakeMaker;
use EV::MakeMaker qw/ev_args/;


{
    package MY;
    sub test_via_harness {
      my($self, $perl, $tests) = @_;
      local $_ = $self->SUPER::test_via_harness($perl, $tests);
      s/PERL_DL_NONLAZY=1//g;
      return $_;
    }
    sub test_via_script {
      my($self, $perl, $tests) = @_;
      local $_ = $self->SUPER::test_via_script($perl, $tests);
      s/PERL_DL_NONLAZY=1//g;
      return $_;
    }
}

my $otherldflags = '';
if ($ARGV[0] eq '-DEBUG') {
    shift @ARGV;
    unshift @ARGV, "OPTIMIZE=-DDEBUG -DDEBUGGING -g";
}
elsif ($ARGV[0] eq '-PROFILE') {
    shift @ARGV;
    unshift @ARGV, "OPTIMIZE=-g -pg -fprofile-arcs -ftest-coverage";
    $otherldflags = '-lgcov';
}


# Set this to false if you get core-dumps. 
# Look for FEERSUM_STEAL in the code to see what this does.
my $steal = 1;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(ev_args(
    NAME              => 'Feersum',
    VERSION_FROM      => 'lib/Feersum.pm',
    ABSTRACT_FROM     => 'lib/Feersum.pm',
    AUTHOR            => 'Jeremy Stashewsky <stash@cpan.org>',
    PREREQ_PM         => {
        'EV'    => 3.8,
        'Guard' => 1.012,
        # for testing,
        'AnyEvent' => 0,
        'Test::More' => 0,
        'Test::Exception' => 0,
    },
    LIBS              => [''],
    DEFINE            => ($steal ? '-DFEERSUM_STEAL' : ''),
    INC               => '-I.', # e.g., '-I. -I/usr/include/other'
	# Un-comment this if you add C files to link with later:
    # OBJECT            => '$(O_FILES)', # link all the C files too
    dynamic_lib => {OTHERLDFLAGS => $otherldflags},
));
