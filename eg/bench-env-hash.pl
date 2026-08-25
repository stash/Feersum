#!/usr/bin/env perl
# Microbenchmark: PSGI env hash creation strategies
#
# Compares:
# 1. newHVhv() clone (current Feersum approach)
# 2. Direct hash building with pre-computed keys
#
# Run: perl eg/bench-env-hash.pl
use strict;
use warnings;
use Benchmark qw(cmpthese);

# Simulate the template hash (similar to feersum_tmpl_env)
my %TEMPLATE = (
    # Constants
    'psgi.version'           => [1, 1],
    'psgi.url_scheme'        => 'http',
    'psgi.run_once'          => 0,
    'psgi.nonblocking'       => 1,
    'psgi.multithread'       => 0,
    'psgi.multiprocess'      => 0,
    'psgi.streaming'         => 1,
    'psgi.errors'            => \*STDERR,
    'psgix.output.buffered'  => 1,
    'psgix.body.scalar_refs' => 1,
    'psgix.output.guard'     => 1,
    'SCRIPT_NAME'            => '',

    # Placeholders (undef in template, set per-request)
    'SERVER_PROTOCOL'        => undef,
    'SERVER_NAME'            => undef,
    'SERVER_PORT'            => undef,
    'REQUEST_URI'            => undef,
    'REQUEST_METHOD'         => undef,
    'PATH_INFO'              => undef,
    'REMOTE_ADDR'            => undef,
    'REMOTE_PORT'            => undef,
    'psgi.input'             => undef,
    'CONTENT_LENGTH'         => 0,
    'QUERY_STRING'           => '',

    # Anticipated headers (placeholders)
    'CONTENT_TYPE'           => undef,
    'HTTP_HOST'              => undef,
    'HTTP_USER_AGENT'        => undef,
    'HTTP_ACCEPT'            => undef,
    'HTTP_ACCEPT_LANGUAGE'   => undef,
    'HTTP_ACCEPT_CHARSET'    => undef,
    'HTTP_KEEP_ALIVE'        => undef,
    'HTTP_CONNECTION'        => undef,
    'HTTP_REFERER'           => undef,
    'HTTP_COOKIE'            => undef,
    'HTTP_IF_MODIFIED_SINCE' => undef,
    'HTTP_IF_NONE_MATCH'     => undef,
    'HTTP_CACHE_CONTROL'     => undef,
    'psgix.io'               => undef,
);

# Pre-extract keys and values for direct building approach
my @TMPL_KEYS = keys %TEMPLATE;
my @TMPL_VALUES = values %TEMPLATE;
my $TMPL_SIZE = scalar @TMPL_KEYS;

# Simulated per-request data
my @REQUEST_DATA = (
    ['SERVER_PROTOCOL', 'HTTP/1.1'],
    ['SERVER_NAME',     'localhost'],
    ['SERVER_PORT',     '8080'],
    ['REQUEST_URI',     '/api/users?page=1'],
    ['REQUEST_METHOD',  'GET'],
    ['PATH_INFO',       '/api/users'],
    ['REMOTE_ADDR',     '127.0.0.1'],
    ['REMOTE_PORT',     '54321'],
    ['QUERY_STRING',    'page=1'],
    ['HTTP_HOST',       'localhost:8080'],
    ['HTTP_USER_AGENT', 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'],
    ['HTTP_ACCEPT',     'text/html,application/xhtml+xml,application/xml;q=0.9'],
    ['HTTP_CONNECTION', 'keep-alive'],
    ['HTTP_COOKIE',     'session=abc123; user=test'],
);

print "=" x 70, "\n";
print "PSGI Env Hash Creation Benchmark\n";
print "=" x 70, "\n";
print "Template keys: $TMPL_SIZE\n";
print "Per-request overrides: ", scalar(@REQUEST_DATA), "\n";
print "=" x 70, "\n\n";

###############################################################################
# Method 1: Hash clone (current approach - simulates newHVhv)
###############################################################################
sub method_clone {
    # Clone template hash
    my %env = %TEMPLATE;

    # Set per-request values
    for my $pair (@REQUEST_DATA) {
        $env{$pair->[0]} = $pair->[1];
    }

    return \%env;
}

###############################################################################
# Method 2: Direct build with assignment
###############################################################################
# Pre-store references to constant values
my $const_psgi_version       = $TEMPLATE{'psgi.version'};
my $const_psgi_url_scheme    = $TEMPLATE{'psgi.url_scheme'};
my $const_psgi_run_once      = $TEMPLATE{'psgi.run_once'};
my $const_psgi_nonblocking   = $TEMPLATE{'psgi.nonblocking'};
my $const_psgi_multithread   = $TEMPLATE{'psgi.multithread'};
my $const_psgi_multiprocess  = $TEMPLATE{'psgi.multiprocess'};
my $const_psgi_streaming     = $TEMPLATE{'psgi.streaming'};
my $const_psgi_errors        = $TEMPLATE{'psgi.errors'};
my $const_psgix_output_buf   = $TEMPLATE{'psgix.output.buffered'};
my $const_psgix_scalar_refs  = $TEMPLATE{'psgix.body.scalar_refs'};
my $const_psgix_output_guard = $TEMPLATE{'psgix.output.guard'};
my $const_script_name        = $TEMPLATE{'SCRIPT_NAME'};

sub method_direct {
    my %env = (
        # Constants (reference same values)
        'psgi.version'           => $const_psgi_version,
        'psgi.url_scheme'        => $const_psgi_url_scheme,
        'psgi.run_once'          => $const_psgi_run_once,
        'psgi.nonblocking'       => $const_psgi_nonblocking,
        'psgi.multithread'       => $const_psgi_multithread,
        'psgi.multiprocess'      => $const_psgi_multiprocess,
        'psgi.streaming'         => $const_psgi_streaming,
        'psgi.errors'            => $const_psgi_errors,
        'psgix.output.buffered'  => $const_psgix_output_buf,
        'psgix.body.scalar_refs' => $const_psgix_scalar_refs,
        'psgix.output.guard'     => $const_psgix_output_guard,
        'SCRIPT_NAME'            => $const_script_name,

        # Per-request values (inline)
        'SERVER_PROTOCOL'        => 'HTTP/1.1',
        'SERVER_NAME'            => 'localhost',
        'SERVER_PORT'            => '8080',
        'REQUEST_URI'            => '/api/users?page=1',
        'REQUEST_METHOD'         => 'GET',
        'PATH_INFO'              => '/api/users',
        'REMOTE_ADDR'            => '127.0.0.1',
        'REMOTE_PORT'            => '54321',
        'QUERY_STRING'           => 'page=1',
        'CONTENT_LENGTH'         => 0,
        'HTTP_HOST'              => 'localhost:8080',
        'HTTP_USER_AGENT'        => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
        'HTTP_ACCEPT'            => 'text/html,application/xhtml+xml,application/xml;q=0.9',
        'HTTP_CONNECTION'        => 'keep-alive',
        'HTTP_COOKIE'            => 'session=abc123; user=test',
    );

    return \%env;
}

###############################################################################
# Method 3: Pre-sized hash with keys()
###############################################################################
sub method_presized {
    my %env;
    keys %env = 40;  # Pre-size

    # Constants
    $env{'psgi.version'}           = $const_psgi_version;
    $env{'psgi.url_scheme'}        = $const_psgi_url_scheme;
    $env{'psgi.run_once'}          = $const_psgi_run_once;
    $env{'psgi.nonblocking'}       = $const_psgi_nonblocking;
    $env{'psgi.multithread'}       = $const_psgi_multithread;
    $env{'psgi.multiprocess'}      = $const_psgi_multiprocess;
    $env{'psgi.streaming'}         = $const_psgi_streaming;
    $env{'psgi.errors'}            = $const_psgi_errors;
    $env{'psgix.output.buffered'}  = $const_psgix_output_buf;
    $env{'psgix.body.scalar_refs'} = $const_psgix_scalar_refs;
    $env{'psgix.output.guard'}     = $const_psgix_output_guard;
    $env{'SCRIPT_NAME'}            = $const_script_name;

    # Per-request
    $env{'SERVER_PROTOCOL'}        = 'HTTP/1.1';
    $env{'SERVER_NAME'}            = 'localhost';
    $env{'SERVER_PORT'}            = '8080';
    $env{'REQUEST_URI'}            = '/api/users?page=1';
    $env{'REQUEST_METHOD'}         = 'GET';
    $env{'PATH_INFO'}              = '/api/users';
    $env{'REMOTE_ADDR'}            = '127.0.0.1';
    $env{'REMOTE_PORT'}            = '54321';
    $env{'QUERY_STRING'}           = 'page=1';
    $env{'CONTENT_LENGTH'}         = 0;
    $env{'HTTP_HOST'}              = 'localhost:8080';
    $env{'HTTP_USER_AGENT'}        = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36';
    $env{'HTTP_ACCEPT'}            = 'text/html,application/xhtml+xml,application/xml;q=0.9';
    $env{'HTTP_CONNECTION'}        = 'keep-alive';
    $env{'HTTP_COOKIE'}            = 'session=abc123; user=test';

    return \%env;
}

###############################################################################
# Method 4: Slice assignment
###############################################################################
my @CONST_KEYS = qw(
    psgi.version psgi.url_scheme psgi.run_once psgi.nonblocking
    psgi.multithread psgi.multiprocess psgi.streaming psgi.errors
    psgix.output.buffered psgix.body.scalar_refs
    psgix.output.guard SCRIPT_NAME
);
my @CONST_VALUES = @TEMPLATE{@CONST_KEYS};

sub method_slice {
    my %env;
    keys %env = 40;

    # Bulk assign constants via slice
    @env{@CONST_KEYS} = @CONST_VALUES;

    # Per-request values
    @env{qw(SERVER_PROTOCOL SERVER_NAME SERVER_PORT REQUEST_URI
            REQUEST_METHOD PATH_INFO REMOTE_ADDR REMOTE_PORT
            QUERY_STRING CONTENT_LENGTH HTTP_HOST HTTP_USER_AGENT
            HTTP_ACCEPT HTTP_CONNECTION HTTP_COOKIE)} =
        ('HTTP/1.1', 'localhost', '8080', '/api/users?page=1',
         'GET', '/api/users', '127.0.0.1', '54321',
         'page=1', 0, 'localhost:8080',
         'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
         'text/html,application/xhtml+xml,application/xml;q=0.9',
         'keep-alive', 'session=abc123; user=test');

    return \%env;
}

###############################################################################
# Verify all methods produce equivalent results
###############################################################################
print "Verifying methods produce equivalent results...\n";
my $ref_env = method_clone();
for my $method (\&method_direct, \&method_presized, \&method_slice) {
    my $test_env = $method->();
    my $ok = 1;
    for my $key (keys %$ref_env) {
        next if !defined $ref_env->{$key} && !defined $test_env->{$key};
        if (!exists $test_env->{$key}) {
            warn "  MISSING key: $key\n";
            $ok = 0; next;
        }
        if (defined $ref_env->{$key} && (!defined $test_env->{$key}
                || $ref_env->{$key} ne $test_env->{$key})) {
            warn "  MISMATCH key: $key\n";
            $ok = 0;
        }
    }
    print $ok ? "  Method OK\n" : "  Method FAILED\n";
}
print "\n";

###############################################################################
# Run benchmark
###############################################################################
print "Running benchmark (5 seconds per method)...\n\n";

cmpthese(-5, {
    'clone'    => \&method_clone,
    'direct'   => \&method_direct,
    'presized' => \&method_presized,
    'slice'    => \&method_slice,
});

print "\n";
print "=" x 70, "\n";
print "Legend:\n";
print "  clone    - Current approach: clone template hash, then set per-request\n";
print "  direct   - Build hash inline with all key-value pairs\n";
print "  presized - Pre-size hash, assign individually\n";
print "  slice    - Pre-size hash, use slice assignment\n";
print "=" x 70, "\n";

###############################################################################
# Also test XS-level comparison if Feersum is available
###############################################################################
print "\n";
eval {
    require Feersum;
    print "Feersum loaded - testing actual env creation would require a running server.\n";
    print "This benchmark simulates the Perl-level equivalent.\n";
};
if ($@) {
    print "Note: Feersum not loaded (run 'make' first if needed).\n";
    print "This benchmark tests Perl-level hash operations which approximate XS behavior.\n";
}
