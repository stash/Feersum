#!perl
# Numeric limit setters take an IV from Perl but store a narrower C type.
# Range-checking after the narrowing let any value >= 2^31 (max_connections)
# or >= 2^32 (max_connection_reqs) wrap negative/zero and read back as
# 0 = "unlimited" - a cap silently becoming no cap.  They clamp now.
use warnings;
use strict;
use Test::More tests => 22;
use lib 't'; use Utils;
use Feersum;

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $f = Feersum->new();
$f->use_socket($socket);

# Ordinary values are untouched.
for my $v (1, 100, 65535, 1_000_000) {
    is $f->max_connections($v), $v, "max_connections($v) round-trips";
}

my $INT_MAX  = 2**31 - 1;
my $UINT_MAX = 2**32 - 1;

is $f->max_connections($INT_MAX), $INT_MAX, 'max_connections(INT_MAX) exact';
is $f->max_connections(2**31), $INT_MAX,
    'max_connections(2**31) clamps to INT_MAX, not 0/unlimited';
is $f->max_connections(2**53), $INT_MAX,
    'max_connections(2**53) clamps to INT_MAX, not 0/unlimited';

# 0 and negative keep their documented "unlimited" meaning.
is $f->max_connections(0), 0, 'max_connections(0) is unlimited';
is $f->max_connections(-1), 0, 'max_connections(-1) is unlimited';

is $f->max_connection_reqs(1000), 1000, 'max_connection_reqs round-trips';
is $f->max_connection_reqs($UINT_MAX), $UINT_MAX,
    'max_connection_reqs(UINT_MAX) exact';
is $f->max_connection_reqs(2**32), $UINT_MAX,
    'max_connection_reqs(2**32) clamps to UINT_MAX, not 0/unlimited';
is $f->max_connection_reqs(2**53), $UINT_MAX,
    'max_connection_reqs(2**53) clamps to UINT_MAX, not 0/unlimited';
is $f->max_connection_reqs(0), 0, 'max_connection_reqs(0) is unlimited';

eval { $f->max_connection_reqs(-1) };
like $@, qr/non-negative/, 'max_connection_reqs(-1) still croaks';

# max_accept_per_loop had the same shape: SvIV narrowed to int BEFORE the
# range check, so anything >= 2**31 went negative and clamped to 1 - the
# smallest batch, when the largest was asked for.
my $INT_MAX = 2**31 - 1;
is $f->max_accept_per_loop(64), 64, 'max_accept_per_loop round-trips';
is $f->max_accept_per_loop($INT_MAX), $INT_MAX,
    'max_accept_per_loop(INT_MAX) exact';
is $f->max_accept_per_loop(2**31), $INT_MAX,
    'max_accept_per_loop(2**31) clamps to INT_MAX, not down to 1';
is $f->max_accept_per_loop(2**40), $INT_MAX,
    'max_accept_per_loop(2**40) clamps to INT_MAX, not down to 1';
is $f->max_accept_per_loop(0), 1, 'max_accept_per_loop(0) floors at 1';
is $f->max_accept_per_loop(-5), 1, 'max_accept_per_loop(-5) floors at 1';
