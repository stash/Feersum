use 5.008007;
use ExtUtils::MakeMaker 6.51;
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
my $convert_deps = 1;
if ($ARGV[0] =~ /^-DEBUG=?(\d*)$/) {
    my $n = $1 || 1;
    my $opt = "OPTIMIZE=-DDEBUG=$n -g";
    # with 5.12.1 and the -DDEBUGGING flag:
    # dyld: Symbol not found: _Perl_pad_sv
    $opt .= ($] >= 5.012_001) ? '' : ' -DDEBUGGING';
    $ARGV[0] = $opt;
}
elsif ($ARGV[0] eq '-PROFILE') {
    shift @ARGV;
    $ARGV[0] = "OPTIMIZE=-g -fprofile-arcs -ftest-coverage";
    $otherldflags = '-lgcov';
}
elsif ($ARGV[0] eq '-PROFILEUSE') {
    $ARGV[0] = "OPTIMIZE=-g -O3 -fprofile-use";
    $otherldflags = '-fprofile-use';
}
elsif ($ARGV[0] eq '-CPAN') {
    $convert_deps = 0;
}

# Convert optional Plack dependency to a real dependency if it's present at
# build-time. (Fix: https://rt.cpan.org/Public/Bug/Display.html?id=65239)
my $plack_req = 0.995;
my $have_plack;
if ($convert_deps) {
    $have_plack = eval 'require Plack; $Plack::VERSION >= 0.995';
}

# Set this to false if you get core-dumps. Gives a pretty good perf boost for
# simple responses. Look for FEERSUM_STEAL in the code to see what this does.
# In a nutshell: certain temporary values passed in as the body of a response
# have their string-value "stolen".  This very much doesn't work under threaded
# perl (5.8.7 and 5.12.1 were tested) and probably doesn't work prior to
# 5.12.0.
use Config;
my $steal = ($] >= 5.012 && !defined($Config{useithreads}));

WriteMakefile(ev_args(
    NAME          => 'Feersum',
    VERSION_FROM  => 'lib/Feersum.pm',
    ABSTRACT_FROM => 'lib/Feersum.pm',
    AUTHOR        => 'Jeremy Stashewsky <stash@cpan.org>',
    LICENSE       => 'perl',
    CONFIGURE_REQUIRES => {
        'EV' => 4.00,
        'ExtUtils::MakeMaker' => 6.51,
    },
    BUILD_REQUIRES => {
        'AnyEvent' => 5.261,
        'Guard' => 1.012,
        'Test::More' => 0.94,
        'Test::Exception' => 0.29,
        'Test::TCP' => 1.06,
    },
    PREREQ_PM => {
        'EV' => 4.00,
        'Scalar::Util' => 1.19,
        ($have_plack ? (Plack => $plack_req) : ()),
    },
    META_MERGE => {
        recommends => {
            ($have_plack ? () : (Plack => $plack_req)),
        },
        resources => {
            repository => 'git://github.com/stash/Feersum.git',
            license => 'http://dev.perl.org/licenses/',
        },
        'no_index' => {directory => ['eg','picohttpparser-git']},
    },
    LIBS   => [''],
    EXE_FILES => ['bin/feersum'],
    DEFINE => ($steal ? '-DFEERSUM_STEAL' : ''),
    INC    => '-I.',
    dynamic_lib => {OTHERLDFLAGS => $otherldflags},
));
