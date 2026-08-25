#!/usr/bin/env perl
# XS-level benchmark comparing env hash creation approaches
#
# Build and run:
#   cd eg/bench-env-xs
#   perl Makefile.PL && make
#   perl bench.pl
#
use strict;
use warnings;
use Benchmark qw(cmpthese);
use lib 'lib', 'blib/lib', 'blib/arch';

use BenchEnv;

print "=" x 70, "\n";
print "XS Benchmark: PSGI Env Hash Creation\n";
print "=" x 70, "\n\n";

# Verify both methods produce valid hashes
print "Verifying hash contents...\n";
my $env_clone = BenchEnv::get_env_clone();
my $env_direct = BenchEnv::get_env_direct();

print "  Clone hash keys: ", scalar(keys %$env_clone), "\n";
print "  Direct hash keys: ", scalar(keys %$env_direct), "\n";

# Check a few values
for my $key (qw(psgi.version REQUEST_METHOD SERVER_NAME HTTP_HOST)) {
    my $v1 = $env_clone->{$key} // 'undef';
    my $v2 = $env_direct->{$key} // 'undef';
    $v1 = ref($v1) ? "[array]" : $v1;
    $v2 = ref($v2) ? "[array]" : $v2;
    print "  $key: clone='$v1' direct='$v2'\n";
}
print "\n";

# Warmup
print "Warming up...\n";
BenchEnv::bench_clone(10000);
BenchEnv::bench_direct(10000);
print "\n";

# Benchmark
print "Running benchmark (5 seconds per method)...\n\n";

my $iterations = 100000;  # iterations per call

cmpthese(-5, {
    'clone' => sub { BenchEnv::bench_clone($iterations) },
    'direct' => sub { BenchEnv::bench_direct($iterations) },
});

print "\n";
print "=" x 70, "\n";
print "Legend:\n";
print "  clone  - Old approach: newHVhv(template) + per-request values\n";
print "  direct - New approach: newHV + constants via SvREFCNT_inc\n";
print "=" x 70, "\n";

# Calculate actual per-hash rate
print "\nDetailed timing (1M hashes each):\n";
use Time::HiRes qw(time);

my $n = 1_000_000;

my $t0 = time();
BenchEnv::bench_clone($n);
my $t1 = time();
BenchEnv::bench_direct($n);
my $t2 = time();

my $clone_time = $t1 - $t0;
my $direct_time = $t2 - $t1;

printf "  clone:  %.3f sec for %d hashes = %.0f hashes/sec (%.2f us/hash)\n",
    $clone_time, $n, $n/$clone_time, ($clone_time/$n)*1_000_000;
printf "  direct: %.3f sec for %d hashes = %.0f hashes/sec (%.2f us/hash)\n",
    $direct_time, $n, $n/$direct_time, ($direct_time/$n)*1_000_000;
printf "\n  Speedup: %.1fx faster\n", $clone_time / $direct_time;
