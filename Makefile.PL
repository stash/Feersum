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
    unshift @ARGV, "OPTIMIZE=-g -O3 -fprofile-arcs -ftest-coverage -fprofile-generate";
    $otherldflags = '-lgcov -fprofile-generate';
}
elsif ($ARGV[0] eq '-PROFILEUSE') {
    shift @ARGV;
    unshift @ARGV, "OPTIMIZE=-g -O3 -fprofile-use";
    $otherldflags = '-fprofile-use';
}

# Set this to false if you get core-dumps. Gives a pretty good perf boost for
# simple responses. Look for FEERSUM_STEAL in the code to see what this does.
# In a nutshell: certain temporary values passed in as the body of a response
# have their string-value "stolen".
my $steal = ($] >= 5.012);

WriteMakefile(ev_args(
    NAME          => 'Feersum',
    VERSION_FROM  => 'lib/Feersum.pm',
    ABSTRACT_FROM => 'lib/Feersum.pm',
    AUTHOR        => 'Jeremy Stashewsky <stash@cpan.org>',
    LICENSE       => 'perl',
    CONFIGURE_REQUIRES => {
        'EV' => 3.9,
        'ExtUtils::MakeMaker' => 6.51,
    },
    BUILD_REQUIRES => {
        'AnyEvent' => 5.261,
        'Guard' => 1.012,
        'Scalar::Util' => 1.19,
        'Test::More' => 0.94,
        'Test::Exception' => 0.29,
    },
    PREREQ_PM => {
        'EV' => 3.9,
    },
    META_MERGE => {
        recommends => {
            'Plack' => 0.9938,
            'Test::TCP' => 0.16,
        },
        resources => {
            repository => 'git://github.com/stash/Feersum.git',
            license => 'http://dev.perl.org/licenses/',
        },
        'no_index' => {directory => ['eg','picohttpparser-git']},
    },
    LIBS   => [''],
    DEFINE => ($steal ? '-DFEERSUM_STEAL' : ''),
    INC    => '-I.',
    dynamic_lib => {OTHERLDFLAGS => $otherldflags},
));
