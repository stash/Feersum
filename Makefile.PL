use 5.014;
use ExtUtils::MakeMaker 6.51;
use EV::MakeMaker qw/ev_args/;

# Unix-only (POSIX sockets, fork, libev epoll/kqueue); NA on Windows.
if ($^O eq 'MSWin32') {
    warn "OS unsupported: Feersum requires a Unix-like OS\n";
    exit 0;
}

# Vendored submodule, not optional.  The tarball ships its sources, so this
# only fires on a git clone made without --recursive.
unless (-f 'picohttpparser-git/picohttpparser.c') {
    die "Feersum: the picohttpparser submodule is missing.\n"
      . "If you are building from a git clone, run:\n"
      . "    git submodule update --init --recursive\n";
}

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
my $force_no_tls = 0;
my $force_no_h2  = 0;

# Filter out our custom flags before MakeMaker sees them
@ARGV = grep {
    if    ($_ eq '-NOTLS') { $force_no_tls = 1; 0 }
    elsif ($_ eq '-NOH2')  { $force_no_h2  = 1; 0 }
    else                   { 1 }
} @ARGV;

if (defined $ARGV[0] && $ARGV[0] =~ /^-DEBUG=?(\d*)$/) {
    my $n = $1 || 1;
    my $opt = "OPTIMIZE=-DDEBUG=$n -g";
    $ARGV[0] = $opt;
}
elsif (defined $ARGV[0] && $ARGV[0] eq '-PROFILE') {
    $ARGV[0] = "OPTIMIZE=-g -fprofile-arcs -ftest-coverage";
    $otherldflags = '-lgcov';
}
elsif (defined $ARGV[0] && $ARGV[0] eq '-PROFILEUSE') {
    $ARGV[0] = "OPTIMIZE=-g -O3 -fprofile-use";
    $otherldflags = '-fprofile-use';
}
elsif (defined $ARGV[0] && $ARGV[0] eq '-CPAN') {
    shift @ARGV;
    $convert_deps = 0;
}

# Convert optional Plack and other dependencies to a real dependency if it's
# present at build-time. (Fix:
# https://rt.cpan.org/Public/Bug/Display.html?id=65239)
my %want = (
    'Plack'           => 0.995,
    'Test::LeakTrace' => 0.13,
    'Test::TCP'       => 1.12,
    'Test::SharedFork'=> 0.25,
    'JSON::XS'        => 2.0,
);
my %have;

# Used only by t/ and xt/.  Without this JSON::XS lands in runtime.requires
# whenever the packager happens to have it installed.
my %test_only = map { $_ => 1 } grep { /^Test::/ } keys %want;
$test_only{q{JSON::XS}} = 1;

if ($convert_deps) {
    local $@;
    while (my ($pkg,$ver) = each %want) {
        $have{$pkg} = eval "require $pkg; \$$pkg\::VERSION >= $ver";
    }
}

use Config;
my $steal = !defined($Config{useithreads});

# Warn when TLS is compiled in but the test-only client libs are absent: every
# TLS/H2 test then skip_all's and the build reports PASS having exercised none.
my $warn_missing_tls_test_deps = sub {
    return unless $_[0];   # $has_tls
    my @missing = grep { !eval "require $_; 1" }
                  qw(IO::Socket::SSL Net::SSLeay);
    return unless @missing;
    warn "Feersum: TLS is enabled but @missing "
       . (@missing > 1 ? "are" : "is") . " not installed;\n"
       . "  the TLS and HTTP/2 test files will be SKIPPED, not run.\n"
       . "  Install them to actually exercise TLS/H2:  cpanm @missing\n";
};

# Optional TLS/H2 support
my (@extra_libs, @extra_defines, @extra_inc, @extra_objects);

# clock_gettime: in librt on glibc < 2.17, in libc on modern glibc/musl.
# Always link -lrt on Linux - harmless on modern systems (empty library).
if ($^O eq 'linux') {
    push @extra_libs, '-lrt';
}

# picotls for TLS 1.3 (vendored submodule in picotls-git/)
# Requires OpenSSL: detected via Alien::OpenSSL or system headers.
my $has_tls = 0;
if ($force_no_tls) {
    warn "Feersum: TLS support disabled (-NOTLS flag)\n";
} elsif (-d 'picotls-git/include' && -f 'picotls-git/lib/picotls.c') {
    # Try Alien::OpenSSL first, then fall back to system OpenSSL detection
    my ($openssl_cflags, $openssl_libs);
    my $alien_ok = 0;
    if (eval { require Alien::OpenSSL; 1 }) {
        # Apply the SAME >= 1.1.0 gate as the system-header probe below.
        # Alien::OpenSSL is a *system* alien, so on a box with OpenSSL 1.0.2 it
        # reports success and picotls then fails to compile; without this the
        # two detection paths disagree for identical inputs.
        my $av = eval { Alien::OpenSSL->version } || '';
        my ($amaj, $amin) = $av =~ /^(\d+)\.(\d+)/ ? ($1, $2) : (0, 0);
        if ($amaj > 1 || ($amaj == 1 && $amin >= 1)) {
            $alien_ok = 1;
        }
        else {
            warn "Feersum: Alien::OpenSSL reports version '$av' (< 1.1.0);"
               . " falling back to system OpenSSL detection\n";
        }
    }
    if ($alien_ok) {
        $openssl_cflags = Alien::OpenSSL->cflags;
        $openssl_libs   = Alien::OpenSSL->libs;
        warn "Feersum: OpenSSL found via Alien::OpenSSL\n";
    } else {
        # Fall back to probing system OpenSSL headers
        require ExtUtils::CBuilder;
        my $cb = ExtUtils::CBuilder->new(quiet => 1);
        my $test_src = "openssl_test_$$.c";
        {
            open my $fh, '>', $test_src or die "Cannot write $test_src: $!";
            # Check for OpenSSL >= 1.1.0 (X25519 support required by picotls)
            print $fh "#include <openssl/opensslv.h>\n";
            print $fh "#if OPENSSL_VERSION_NUMBER < 0x10100000L\n";
            print $fh "#error OpenSSL too old for picotls (need >= 1.1.0)\n";
            print $fh "#endif\n";
            print $fh "#include <openssl/evp.h>\n";
            print $fh "int main() { return 0; }\n";
            close $fh;
        }
        my $has_openssl = eval { $cb->compile(source => $test_src); 1 };
        unlink $test_src, glob("openssl_test_$$.*");

        if ($has_openssl) {
            $openssl_cflags = '';
            $openssl_libs   = '-lssl -lcrypto';
            warn "Feersum: OpenSSL found via system headers\n";
        }
    }

    if (defined $openssl_libs) {
        push @extra_inc,     '-Ipicotls-git/include';
        push @extra_inc,     $openssl_cflags if $openssl_cflags && $openssl_cflags =~ /\S/;
        push @extra_defines, '-DFEERSUM_HAS_TLS';
        push @extra_libs,    $openssl_libs;
        # Build picotls source files as object files
        push @extra_objects, 'picotls-core.o', 'picotls-openssl.o', 'picotls-pembase64.o', 'picotls-hpke.o';
        $has_tls = 1;
        warn "Feersum: TLS support enabled (picotls vendored submodule)\n";
    } else {
        warn "Feersum: TLS support disabled (OpenSSL not found; install Alien::OpenSSL or OpenSSL dev headers)\n";
    }
} else {
    warn "Feersum: TLS support disabled (picotls-git submodule not found)\n";
}

# Optional: nghttp2 for HTTP/2 (via Alien::nghttp2, requires TLS)
# Requires nghttp2 >= 1.34.0 for NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 8441)
if ($force_no_h2) {
    warn "Feersum: HTTP/2 support disabled (-NOH2 flag)\n";
} elsif ($has_tls && eval { require Alien::nghttp2; 1 }) {
    my $cflags = Alien::nghttp2->cflags;
    my $libs   = Alien::nghttp2->libs;

    # Verify nghttp2 is new enough (need NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL)
    require ExtUtils::CBuilder;
    my $cb = ExtUtils::CBuilder->new(quiet => 1);
    my $test_src = "nghttp2_test_$$.c";
    {
        open my $fh, '>', $test_src or die "Cannot write $test_src: $!";
        print $fh "#include <nghttp2/nghttp2.h>\n";
        print $fh "int main() { return NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL; }\n";
        close $fh;
    }
    my @compile_args = (source => $test_src);
    push @compile_args, (extra_compiler_flags => $cflags) if $cflags =~ /\S/;
    my $h2_linked;
    my $h2_ok = eval {
        my $obj = $cb->compile(@compile_args);
        # Build as shared library and dlopen to catch missing transitive deps
        # (e.g. libelf on FreeBSD) - executable link succeeds but dlopen fails.
        $h2_linked = $cb->link(
            objects            => $obj,
            extra_linker_flags => $libs,
            module_name        => "nghttp2_test_$$",
        );
        require DynaLoader;
        use Cwd 'abs_path';
        my $abs = abs_path($h2_linked)
            or die "abs_path($h2_linked) failed";
        my $dlh = DynaLoader::dl_load_file($abs, 0);
        die "dlopen failed: " . DynaLoader::dl_error() unless $dlh;
        DynaLoader::dl_unload_file($dlh) if defined &DynaLoader::dl_unload_file;
        1;
    };
    unlink $test_src, $h2_linked // (), glob("nghttp2_test_$$.*");

    if ($h2_ok) {
        push @extra_inc,     $cflags if $cflags =~ /\S/;
        push @extra_libs,    $libs;
        push @extra_defines, '-DFEERSUM_HAS_H2';
        warn "Feersum: HTTP/2 support enabled (nghttp2 via Alien::nghttp2)\n";
    } else {
        warn "Feersum: HTTP/2 support disabled (nghttp2 compile/link test failed, need >= 1.34.0)\n";
    }
} elsif ($has_tls) {
    warn "Feersum: HTTP/2 support disabled (Alien::nghttp2 not found)\n";
}

# picotls and our own headers use C99 idioms (for-loop initial decls). Older
# perls were built with compilers that default to C89, where this fails to
# compile. Force C99 (with GNU extensions) when the compiler looks like
# gcc/clang; leave it alone otherwise so non-GCC toolchains keep their own
# defaults.
my $ccflags = $Config{ccflags};
if ($Config{cc} =~ /\b(gcc|clang|cc)\b/ &&
    $ccflags !~ /-std=(c99|gnu99|c11|gnu11|c17|gnu17|c2[03x]|gnu2[03x])\b/)
{
    $ccflags .= ' -std=gnu99';
}

$warn_missing_tls_test_deps->($has_tls);

# Generated from lib/ so it cannot drift as packages are added or moved.
my %provides;
if (eval { require Module::Metadata; 1 }) {
    %provides = %{ Module::Metadata->provides(version => 2, dir => 'lib') || {} };
}

WriteMakefile(ev_args(
    NAME          => 'Feersum',
    VERSION_FROM  => 'lib/Feersum.pm',
    ABSTRACT_FROM => 'lib/Feersum.pm',
    AUTHOR        => 'Jeremy Stashewsky <stash@cpan.org>',
    LICENSE       => 'perl',
    MIN_PERL_VERSION => '5.014',
    CCFLAGS       => $ccflags,
    CONFIGURE_REQUIRES => {
        'EV' => 4.00,
        'EV::MakeMaker' => 0,
        'ExtUtils::CBuilder' => 0,
        'ExtUtils::MakeMaker' => 6.51,
    },
    BUILD_REQUIRES => {
        'AnyEvent' => 5.261,
        'Test::More' => 0.94,
        'Test::Fatal' => 0.003,
        # IO::Socket::SSL / Net::SSLeay stay recommends, not requires: they are
        # the TLS/H2 test client and unused at runtime, so a failed Net::SSLeay
        # build must not block installing a module that does not need it.
        map { $_ => $want{$_} } grep { $test_only{$_} && $have{$_} } keys %want
    },
    PREREQ_PM => {
        'EV' => 4.00,
        'Guard' => 1.012,
        'Scalar::Util' => 1.19,
        'File::Spec' => 0,
        # Runner uses List::Util::any, added in 1.33; core perl 5.14-5.18 ships 1.23-1.27
        'List::Util' => 1.33,
        map { $_ => $want{$_} } grep { !$test_only{$_} && $have{$_} } keys %want
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        (%provides ? (provides => \%provides) : ()),
        prereqs => {
            runtime => {
                recommends => {
                    'Alien::OpenSSL' => 0,
                    'Alien::nghttp2' => 0,
                    map { $_ => $want{$_} } grep { !$test_only{$_} && !$have{$_} } keys %want
                },
            },
            test => {
                recommends => {
                    'IO::Socket::SSL' => 0,
                    'Net::SSLeay'     => 0,
                    map { $_ => $want{$_} } grep { $test_only{$_} && !$have{$_} } keys %want
                },
            },
            # The t/99-* release gates die (not skip) when RELEASE_TESTING is
            # set and these are missing, so CI depended on the base image
            # happening to ship them.  Declaring them makes that explicit.
            develop => {
                requires => {
                    'Perl::Critic'         => '1.098',
                    'Test::Perl::Critic'   => '1.01',
                    'Test::DistManifest'   => '1.003',
                    'Test::Pod'            => '1.26',
                    'Test::Pod::Coverage'  => '1.08',
                    'Pod::Simple'          => '3.07',
                    'Test::Fixme'          => '0.04',
                },
            },
        },
        resources => {
            # Where this code actually lives.  Bugs still go upstream.
            repository => {
                url  => 'https://github.com/vividsnow/Feersum.git',
                web  => 'https://github.com/vividsnow/Feersum',
                type => 'git',
            },
            bugtracker => {
                web => 'https://github.com/stash/Feersum/issues',
            },
            license => [ 'http://dev.perl.org/licenses/' ],
        },
        'no_index' => {directory => ['eg','picohttpparser-git','picotls-git']},
    },
    LIBS   => [join(' ', @extra_libs) || ''],
    EXE_FILES => ['bin/feersum'],
    DEFINE => join(' ', ($steal ? '-DFEERSUM_STEAL' : ''), @extra_defines),
    INC    => join(' ', '-I.', @extra_inc),
    dynamic_lib => {OTHERLDFLAGS => $otherldflags},
    (@extra_objects ? (OBJECT => '$(BASEEXT)$(OBJ_EXT) ' . join(' ', @extra_objects)) : ()),
    # The .c.inc and .h files are #included by the C compiler, so the object
    # depends on them.  feersum_conn.xs is different: Feersum.xs pulls it in
    # with xsubpp's "INCLUDE:", which is expanded when Feersum.c is GENERATED.
    # Listing it only against the object rebuilds the object from a stale
    # Feersum.c, so edits to it silently keep the previous binary - hence the
    # separate dependency on Feersum.c.
    depend => {
        # Feersum.xs also #includes rinq.c and the vendored picohttpparser, and
        # glob("*.c.inc *.h") matches neither: editing rinq.c, or a submodule
        # update bumping picohttpparser, produced NO compiler invocation at all
        # and shipped a byte-identical binary built from the old source.
        "Feersum\$(OBJ_EXT)" => join(" ", glob("*.c.inc *.h"),
            "rinq.c",
            "picohttpparser-git/picohttpparser.c",
            "picohttpparser-git/picohttpparser.h",
            "feersum_conn.xs"),
        "Feersum.c"          => "feersum_conn.xs",
    },
));

# Custom build rules for picotls object files
package MY;

# EUMM's init_dirscan sweeps every top-level *.pl/*.pm/*.pod into PM -
# dotfiles included - so a stray scratch file like .audit_scan.pl in the
# working tree is copied into blib and then installed into site_perl, and it
# also gets picked up by the author-side POD/critic tests.  Nothing shipped by
# this dist starts with a dot, so drop those entries.
sub init_dirscan {
    my $self = shift;
    $self->SUPER::init_dirscan(@_);
    for my $k (keys %{ $self->{PM} || {} }) {
        delete $self->{PM}{$k} if $k =~ m{(?:^|/)\.[^/]*\z};
    }
    return;
}

sub postamble {
    my $self = shift;
    my $postamble = '';
    if (-d 'picotls-git/include') {
        $postamble .= <<'MAKE';

picotls-core.o: picotls-git/lib/picotls.c picotls-git/include/picotls.h
	$(CC) -c $(PASTHRU_INC) $(INC) $(CCFLAGS) $(OPTIMIZE) $(CCCDLFLAGS) $(DEFINE) -Ipicotls-git/include -o picotls-core.o picotls-git/lib/picotls.c

picotls-openssl.o: picotls-git/lib/openssl.c picotls-git/include/picotls/openssl.h picotls-git/include/picotls.h
	$(CC) -c $(PASTHRU_INC) $(INC) $(CCFLAGS) $(OPTIMIZE) $(CCCDLFLAGS) $(DEFINE) -Ipicotls-git/include -o picotls-openssl.o picotls-git/lib/openssl.c

picotls-pembase64.o: picotls-git/lib/pembase64.c picotls-git/include/picotls.h picotls-git/include/picotls/pembase64.h
	$(CC) -c $(PASTHRU_INC) $(INC) $(CCFLAGS) $(OPTIMIZE) $(CCCDLFLAGS) $(DEFINE) -Ipicotls-git/include -o picotls-pembase64.o picotls-git/lib/pembase64.c

picotls-hpke.o: picotls-git/lib/hpke.c picotls-git/include/picotls.h
	$(CC) -c $(PASTHRU_INC) $(INC) $(CCFLAGS) $(OPTIMIZE) $(CCCDLFLAGS) $(DEFINE) -Ipicotls-git/include -o picotls-hpke.o picotls-git/lib/hpke.c

MAKE
    }


    $postamble .= <<'MAKE';

clean ::
	$(RM_F) picotls-core.o picotls-openssl.o picotls-pembase64.o picotls-hpke.o

MAKE
    return $postamble;
}
