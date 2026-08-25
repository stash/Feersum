#!perl
# #7: _drop_privs called setgroups unconditionally.  setgroups needs CAP_SETGID,
# so a non-root start that just names the user it already is (a systemd unit
# with User=bob plus Feersum user => 'bob', say) got EPERM and refused to start.
# It now skips setgroups when there are no root groups to shed anyway.
use warnings;
use strict;
use Test::More;
use Test::Fatal;
use lib 't'; use Utils;
use Feersum::Runner ();

plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
plan skip_all => 'must run as non-root to exercise the setgroups path'
    if $> == 0 || $< == 0;
my $user = getpwuid($<);
plan skip_all => 'cannot resolve the current user' unless defined $user;
my (undef, undef, $uid, $pgid) = getpwnam($user);
plan skip_all => 'current user has no passwd entry' unless defined $uid;
my ($rgid) = split ' ', $(;
# setgid to a group we are not already in needs privilege too (and rightly
# croaks); this test isolates the setgroups regression, so require the match.
plan skip_all => 'current gid is not the user primary gid (unusual setup)'
    if !defined $pgid || $pgid != $rgid;

plan tests => 2;

# Only the fields _drop_privs reads; no reuseport or pid_file side effects.
my $r = bless { user => $user }, 'Feersum::Runner';
is exception { $r->_drop_privs }, undef,
    'user => the user we already are does not croak (setgroups skipped)';
is $<, $uid, 'still running as the same uid afterwards';
