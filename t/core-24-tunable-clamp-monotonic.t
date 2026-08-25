#!perl
# A range-checked setter is monotonic non-decreasing in its input: a huge value
# clamps to the maximum and never falls off the bottom of the clamp to the
# minimum (SvIV returns IV_MIN or -1 past its range).
use warnings;
use strict;
use Test::More;
use Feersum;

my $INT_MAX  = 2147483647;
my $UINT_MAX = 4294967295;

# Ascending inputs that straddle both cliffs (2**31 and 2**63) and run to Inf.
my @ASC = (1, 2, 100, $INT_MAX - 1, $INT_MAX, 2**31, 2**32, 2**32 + 5,
           2**53, 2**63, 18446744073709551615, 9**9**9);

my $h2 = Feersum->new_instance->has_h2();

# [setter, ceiling it must reach, floor for out-of-range-low input]
my @TUNABLES = (
    [read_priority             => 2,          -2],
    [write_priority            => 2,          -2],
    [accept_priority           => 2,          -2],
    [max_accept_per_loop       => $INT_MAX,    1],
    [max_connections           => $INT_MAX,    undef],  # 0 = unlimited
    [max_read_buf              => undef,       undef],
    [max_body_len              => undef,       undef],
    [max_uri_len               => undef,       undef],
    [wbuf_low_water            => undef,       undef],
    [max_connection_reqs       => $UINT_MAX,   undef],
    ($h2 ? [max_h2_concurrent_streams => 100,  1] : ()),
);

plan tests => 2 * @TUNABLES + 3;

for my $t (@TUNABLES) {
    my ($setter, $ceiling) = @$t;
    my $f = Feersum->new_instance;

    my (@got, $monotonic);
    $monotonic = 1;
    for my $in (@ASC) {
        # A croak on a large positive input is itself the failure: record it
        # rather than dying, so one bad knob does not hide the rest.
        push @got, eval { $f->$setter($in); $f->$setter() } // 'CROAK';
        $monotonic = 0
            if @got > 1 && ($got[-1] eq 'CROAK' || $got[-1] < $got[-2]);
    }
    ok $monotonic, "$setter is monotonic across 1 .. Inf"
        or diag "readbacks: @got";

    SKIP: {
        skip "$setter has no fixed ceiling", 1 unless defined $ceiling;
        is $got[-1], $ceiling,
            "$setter(Inf) clamps up to $ceiling, not down to the minimum";
    }
}

# The three that landed on the minimum before the fix, named explicitly so a
# regression says which knob broke rather than only "not monotonic".
my $f = Feersum->new_instance;
$f->accept_priority(2**31);
is $f->accept_priority, 2, "accept_priority(2**31) is the highest, not the lowest";
$f->max_accept_per_loop(2**63);
is $f->max_accept_per_loop, $INT_MAX, "max_accept_per_loop(2**63) is the largest batch, not 1";
SKIP: {
    skip "no H2 support", 1 unless $h2;
    $f->max_h2_concurrent_streams(2**31);
    is $f->max_h2_concurrent_streams, 100,
        "max_h2_concurrent_streams(2**31) advertises 100 streams, not 1";
}
