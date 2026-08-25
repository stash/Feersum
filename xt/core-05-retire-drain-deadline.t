#!perl
# graceful_timeout must bound a max_requests_per_worker retirement, not just an
# operator shutdown.  The replacement worker is forked only when the retiring
# one exits, so an unbounded drain leaves the slot empty for as long as one
# slow connection cares to hold it - at pre_fork => 1, a total outage.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 5;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);
use POSIX ();
use IO::Socket::INET;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

use constant GRACEFUL => 2 * TIMEOUT_MULT;

# Raw sockets rather than simple_client: this polls a server that is expected
# to be unresponsive for a while, and each attempt must fail quietly.
sub raw_get {
    my ($port, $timeout) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => $timeout) or return undef;
    $s->autoflush(1);
    print {$s} "GET / HTTP/1.0\r\nHost: h\r\n\r\n";
    my $buf = '';
    my $deadline = time + $timeout;
    my $rin = ''; vec($rin, fileno($s), 1) = 1;
    while ((my $left = $deadline - time) > 0) {
        select(my $rout = $rin, undef, undef, $left) or last;
        sysread($s, my $chunk, 4096) or last;
        $buf .= $chunk;
        last if $buf =~ /pid=\d+/;
    }
    close $s;
    return $buf =~ /pid=(\d+)/ ? $1 : undef;
}

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/retire-drain.feersum";
open my $fh, '>', $app or die "open $app: $!";
print $fh <<'APP';
my %HELD;
sub {
    my $r = shift;
    if (($r->env->{PATH_INFO} || '') eq '/stream') {
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/event-stream']);
        $w->write("data: hi\n\n");
        $HELD{"$w"} = $w;          # never closed
        return;
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'], \"pid=$$\n");
}
APP
close $fh;

my (undef, $port) = get_listen_socket();
my $master = fork // die "fork: $!";
if (!$master) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port"], app_file => $app,
            pre_fork => 1, max_requests_per_worker => 2,
            graceful_timeout => GRACEFUL, quiet => 1,
        )->run();
    };
    POSIX::_exit(0);
}

sleep 1.0 * TIMEOUT_MULT;

# A stream the worker can never finish writing, so the drain can never complete
# on its own.
my $held = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                 Timeout => 3 * TIMEOUT_MULT);
ok $held, "opened a streaming connection";
if ($held) {
    $held->autoflush(1);
    print {$held} "GET /stream HTTP/1.1\r\nHost: h\r\n\r\n";
    my $rin = ''; vec($rin, fileno($held), 1) = 1;
    select(my $rout = $rin, undef, undef, 3 * TIMEOUT_MULT);
    sysread($held, my $junk, 4096);
}

# Request 2 of 2: served normally, and retiring the worker on its way out.
my $wpid = raw_get($port, 3 * TIMEOUT_MULT);
ok $wpid, "got worker pid (".($wpid // 'undef').")";
my $retired_at = time;

# Watch the worker PROCESS, not the service.  Whether a replacement is
# accepting yet depends on the supervisor's fork and the kernel's accept
# queue; whether this worker exits depends only on the deadline under test.
my $limit = GRACEFUL + 20 * TIMEOUT_MULT;
my $elapsed;
while ((my $left = $retired_at + $limit - time) > 0) {
    unless (kill 0, $wpid) { $elapsed = time - $retired_at; last }
    sleep 0.2;
}

ok defined $elapsed, "the retiring worker exited on its own";
cmp_ok $elapsed // $limit, '<', GRACEFUL + 10 * TIMEOUT_MULT,
    sprintf "retirement drain was bounded by graceful_timeout (%.1fs)",
            $elapsed // -1;
# It must not have taken the whole server with it: something serves again.
ok defined raw_get($port, 10 * TIMEOUT_MULT), "the pool recovered";

close $held if $held;
reap_server($master);
