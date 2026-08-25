#!perl
# The H2 test helper: h2_read_frame returns a whole frame or an error, never a
# short payload when a frame is split across its read deadline.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
# The gap must outlast the read deadline for the split to happen at all, so
# both scale together - unscaled 0.2s/0.6s lost the race on loaded smokers.
use constant READ_TMO => 0.3 * TIMEOUT_MULT;
use constant FEED_GAP => 1.2 * TIMEOUT_MULT;
use Test::More tests => 6;
use lib 't';
use AnyEvent;
use H2Utils;
use Socket;
use POSIX ();
use Time::HiRes qw(sleep);

# Deliver $wire in two pieces separated by a gap longer than the read timeout.
sub split_feed {
    my ($wire, $first_n, $gap) = @_;
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    $a->autoflush(1); $b->autoflush(1);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $a;
        syswrite $b, substr($wire, 0, $first_n);
        sleep $gap;
        syswrite $b, substr($wire, $first_n);
        sleep 1 * TIMEOUT_MULT;
        POSIX::_exit(0);
    }
    close $b;
    $a->blocking(0);
    # Wait for the FIRST piece before handing the socket back.  The read
    # deadline below has to expire in the GAP, not while the loaded box is
    # still getting round to fork()+syswrite: that is what made this test fail
    # on a smoker whose suite took 1731s.
    my $rin = ''; vec($rin, fileno($a), 1) = 1;
    select($rin, undef, undef, 30 * TIMEOUT_MULT);
    return ($a, $pid);
}

my $wire = h2_frame(H2_DATA, 0, 1, 'A' x 20) . h2_frame(H2_PING, 0, 0, 'PINGPING');

# Split in the middle of the payload.
{
    my ($s, $pid) = split_feed($wire, 9 + 5, FEED_GAP);
    my $f1 = eval { h2_read_frame($s, READ_TMO) };
    ok $f1, 'split mid-payload still yields a frame' or diag $@;
    is length($f1->{payload}), $f1->{length},
        'payload is complete, not truncated to what had arrived';
    my $f2 = eval { h2_read_frame($s, 3 * TIMEOUT_MULT) };
    is +($f2 ? $f2->{type} : -1), H2_PING,
        'the following frame still parses (connection not desynchronised)';
    close $s; waitpid $pid, 0;
}

# Split in the middle of the 9-byte header.
{
    my ($s, $pid) = split_feed($wire, 4, FEED_GAP);
    my $f1 = eval { h2_read_frame($s, READ_TMO) };
    is +($f1 ? $f1->{type} : -1), H2_DATA,
        'split mid-header reassembles instead of discarding the bytes read';
    my $f2 = eval { h2_read_frame($s, 3 * TIMEOUT_MULT) };
    is +($f2 ? $f2->{type} : -1), H2_PING, 'and the next frame is still aligned';
    close $s; waitpid $pid, 0;
}

# A clean frame boundary with nothing to read must stay a quiet undef, since
# callers poll with a short timeout and treat undef as "nothing yet".
{
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    $a->blocking(0);
    my $f = eval { h2_read_frame($a, READ_TMO) };
    is $f, undef, 'no data at a frame boundary returns undef, not an error';
    close $a; close $b;
}
