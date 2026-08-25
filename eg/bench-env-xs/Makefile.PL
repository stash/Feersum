use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'BenchEnv',
    VERSION_FROM => 'lib/BenchEnv.pm',
    AUTHOR       => 'Feersum',
    ABSTRACT     => 'XS benchmark for PSGI env hash creation',
);
