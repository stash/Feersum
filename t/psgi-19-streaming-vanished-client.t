#!perl
# A client that vanishes mid-stream is noticed only on the next write to it
# (no timer covers an idle streaming connection, by design), and a periodic
# heartbeat write is the documented mitigation; both halves are pinned.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 6;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $dir = tempdir(CLEANUP => 1);
my $CAP = 3;

# $heartbeat: whether the server writes to its held writers periodically.
sub run_server {
    my ($heartbeat, $sock, $stat) = @_;
    my $pid = fork // die "fork: $!";
    return $pid if $pid;
    open STDOUT, ">", "$dir/srv.$heartbeat.out";
    open STDERR, ">", "$dir/srv.$heartbeat.log";
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->max_connections($CAP);
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    my %keep;
    $f->request_handler(sub {
        my $w = shift->start_streaming(200, ['Content-Type' => 'text/event-stream']);
        $w->write("data: hello\n\n");
        $keep{0 + $w} = $w;
    });
    my $hb;
    if ($heartbeat) {
        $hb = EV::timer 0.5, 0.5, sub {
            for my $k (keys %keep) {
                my $w = $keep{$k};
                eval { $w->write("data: ping\n\n"); 1 } or delete $keep{$k};
            }
        };
    }
    # Write-then-rename: a reader must never catch this file mid-write and
    # read an empty sample.
    my $rep = EV::timer 0, 0.2, sub {
        open my $h, '>', "$stat.tmp" or return;
        print {$h} $f->active_conns, "\n";
        close $h;
        rename "$stat.tmp", $stat;
    };
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}

sub active {
    my ($stat) = @_;
    open my $h, '<', $stat or return -1;
    my $n = <$h> // -1;
    close $h;
    chomp $n;
    return $n;
}

sub stream_client {
    my ($port) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 5 * TIMEOUT_MULT) or return;
    my $got = q{};
    my $ok = eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 6 * TIMEOUT_MULT;
        print {$s} "GET /sse HTTP/1.1\r\nHost: x\r\n\r\n";
        while ($got !~ /hello/) {
            my $n = sysread $s, my $z, 65536;
            last if !$n;
            $got .= $z;
        }
        alarm 0;
        1;
    };
    alarm 0;
    return ($ok && $got =~ /hello/) ? $s : undef;
}

# Returns the settled active_conns after every client has vanished.
sub drain_test {
    my ($heartbeat) = @_;
    my ($sock, $port) = get_listen_socket();
    my $stat = "$dir/stat.$heartbeat";
    unlink $stat;
    my $pid = run_server($heartbeat, $sock, $stat);
    close $sock;

    # Wait for the server's first sample before trusting any reading: -1 means
    # "no sample yet", and treating that as a count made a slow start look
    # like a behaviour difference.
    my $up = 0;
    for (1 .. 100) {
        select undef, undef, undef, 0.1 * TIMEOUT_MULT;
        if (active($stat) >= 0) { $up = 1; last }
    }
    diag "server never reported active_conns" unless $up;

    my @cli;
    for (1 .. $CAP) { my $c = stream_client($port); push @cli, $c if $c }
    my $opened = scalar @cli;
    close $_ for @cli;

    my $settled = -1;
    for (1 .. 40) {
        select undef, undef, undef, 0.4 * TIMEOUT_MULT;
        my $now = active($stat);
        next if $now < 0;              # sample not readable this instant
        $settled = $now;
        last if $settled == 0;
    }
    # Can the server still serve a new client?
    my $recovered = stream_client($port) ? 1 : 0;

    reap_server($pid);
    unlink $stat;
    return ($opened, $settled, $recovered);
}

sub diag_srv {
    my ($hb) = @_;
    for my $f ("$dir/srv.$hb.log", "$dir/srv.$hb.out") {
        next unless -s $f;
        open my $h, "<", $f or next;
        local $/;
        diag "$f:\n" . <$h>;
        close $h;
    }
}

my ($op1, $left1, $rec1) = drain_test(0);
is $op1, $CAP, "no heartbeat: opened $CAP streaming clients";
is $left1, $CAP,
    'no heartbeat: vanished streams are still counted (documented behaviour)';
diag_srv(0) if $left1 != $CAP;
is $rec1, 0,
    'no heartbeat: dead streams fill max_connections and the server stops serving';

my ($op2, $left2, $rec2) = drain_test(1);
is $op2, $CAP, "heartbeat: opened $CAP streaming clients";
is $left2, 0, 'heartbeat: the write detects departure and releases the slots';
is $rec2, 1, 'heartbeat: the server keeps serving new clients';
