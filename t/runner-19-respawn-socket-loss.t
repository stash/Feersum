#!perl
# A respawn that cannot use its inherited listen sockets must arm a retry
# rather than warn and drop the worker slot for good.
use warnings;
use strict;
use Test::More;

BEGIN {
    plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
}
plan tests => 4;

use_ok('Feersum::Runner');

my $r = Feersum::Runner->new(
    listen => ['localhost:0'], app => sub { [200, [], ['']] }, quiet => 1,
);

open my $dead, '<', '/dev/null' or die "open: $!";
close $dead;                          # fileno now returns undef
ok !defined(fileno $dead), 'prepared a listen handle whose fileno is undef';

$r->{_use_reuseport} = 0;
$r->{_socks} = [$dead];

my @retried;
{
    no warnings 'redefine';
    local *Feersum::Runner::_retry_respawn = sub {
        my ($self, $slot, $err) = @_;
        push @retried, [$slot, $err];
    };
    local $SIG{__WARN__} = sub { };
    $r->_respawn_worker(3);
}

is scalar(@retried), 1, 'an unusable listen socket arms a respawn retry';
is $retried[0][0], 3, '...for the slot that failed';
