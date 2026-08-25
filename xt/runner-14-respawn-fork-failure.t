#!perl
# A fork() failure during respawn happens inside an EV watcher callback, which
# discards exceptions: the slot must still recover, and the supervisor, which
# re-listens around the fork, must not serve requests itself in the meantime.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use File::Temp qw(tempdir);
use POSIX ();

plan skip_all => 'author test' unless $ENV{FEERSUM_AUTHOR_TESTS} || $ENV{AUTHOR_TESTING};
plan tests => 5;

use lib 't'; use Utils;

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/app.feersum";
open my $fh, '>', $app or die $!;
print {$fh} 'sub { $_[0]->send_response(200, ["Content-Type"=>"text/plain"], ["pid=$$\n"]) }';
close $fh;

my (undef, $port) = get_listen_socket();

# The supervisor runs in a child.  _fork_another is wrapped so the FIRST
# respawn attempt dies the way a real fork() failure would, before any
# bookkeeping; later attempts behave normally.
my $sup = fork();
die "fork: $!" unless defined $sup;
if (!$sup) {
    require Feersum::Runner;
    no warnings 'redefine', 'once';
    my $orig = \&Feersum::Runner::_fork_another;
    my $calls = 0;
    *Feersum::Runner::_fork_another = sub {
        my ($self, $slot) = @_;
        # Call 1 is the startup fork and must succeed.  Call 2 is the first
        # respawn: that is the one made to fail the way a real fork(2) would,
        # before any bookkeeping, so the unwind path matches.
        die "failed to fork: Resource temporarily unavailable\n"
            if ++$calls == 2;
        return $orig->($self, $slot);
    };
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port"], app_file => $app,
            pre_fork => 1, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

sub fetch {
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 5 * TIMEOUT_MULT) or return;
    syswrite $s, "GET / HTTP/1.0\r\n\r\n";
    my ($buf, $g) = (q{});
    while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
    close $s;
    return $buf =~ /pid=(\d+)/ ? $1 : undef;
}

sub wait_for_serving {
    my ($budget) = @_;
    my $deadline = time + $budget;
    while (time < $deadline) {
        my $pid = fetch();
        return $pid if defined $pid;
        select undef, undef, undef, 0.25;
    }
    return;
}

my $first = wait_for_serving(15 * TIMEOUT_MULT);
ok defined($first), 'supervisor started and a worker serves'
    or diag 'no worker ever answered';
isnt $first, $sup, 'the responder is a worker, not the supervisor itself';

# Kill the worker: the reaper fires _respawn_worker, whose first fork attempt
# dies inside the EV callback.
kill 'TERM', $first if defined $first;

# The slot must come back on its own through the backoff retry.
my $second = wait_for_serving(25 * TIMEOUT_MULT);
ok defined($second), 'slot recovers after a failed fork (retry was armed)'
    or diag 'slot stranded: nothing answered after the fork failure';
isnt $second, $sup, 'the supervisor is still not serving requests itself'
    or diag "supervisor=$sup first_worker=" . ($first // 'undef')
          . " responder=" . ($second // 'undef')
          . " - unlisten was skipped on the croak path";
isnt $second, $first, 'a new worker replaced the killed one';

reap_server($sup);
