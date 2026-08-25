#!perl
# graceful_shutdown() closes connections idle at shutdown-begin; one with a
# sendfile in flight is not idle and must finish, delivering the whole promised
# Content-Length.  Under Feersum::Runner, graceful_timeout may still cut it.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use File::Temp qw(tempfile);
use POSIX ();

plan skip_all => 'author test' unless $ENV{FEERSUM_AUTHOR_TESTS} || $ENV{AUTHOR_TESTING};
plan skip_all => 'sendfile() is only supported on Linux' unless $^O eq 'linux';
plan tests => 5;

use lib 't'; use Utils;
use Feersum;

my ($tfh, $file) = tempfile(UNLINK => 1);
print {$tfh} ('A' x 1024) for 1 .. (8 * 1024);   # 8 MB: many EAGAIN resumes
close $tfh;
my $size = -s $file;
ok $size == 8 * 1024 * 1024, "test file is $size bytes";

my ($sock, $port) = get_listen_socket();
ok $sock, "got listen socket on port $port";

pipe my $rd, my $wr or die "pipe: $!";
my $client = fork();
die "fork: $!" unless defined $client;
if (!$client) {
    close $sock;
    close $rd;
    select undef, undef, undef, 0.5 * TIMEOUT_MULT;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 10 * TIMEOUT_MULT);
    if (!$s) { print {$wr} "0 0\n"; POSIX::_exit(0) }
    syswrite $s, "GET /file HTTP/1.1\r\nHost: x\r\n\r\n";
    my ($buf, $got, $cl, $hl) = (q{}, 0, undef, undef);
    my $last = time;
    $s->blocking(0);
    while (1) {
        my $rin = q{};
        vec($rin, fileno($s), 1) = 1;
        if (!select $rin, undef, undef, 1) {
            # A keepalive conn never EOFs, so completion is keyed on content:
            # stop once the promised body has arrived, or after a real stall.
            last if defined $cl && ($got - ($hl // 0)) >= $cl;
            last if time - $last > 15 * TIMEOUT_MULT;
            next;
        }
        my $g = sysread $s, my $z, 32768;
        last if defined $g && $g == 0;
        next if !defined $g;
        $last = time;
        $got += $g;
        if (!defined $hl) {
            $buf .= $z;
            if ($buf =~ /\r\n\r\n/) {
                my ($h) = split /\r\n\r\n/, $buf, 2;
                $hl = length($h) + 4;
                ($cl) = $h =~ /^Content-Length:\s*(\d+)/mi;
                $buf = q{};
            }
        }
        last if defined $cl && ($got - $hl) >= $cl;
        select undef, undef, undef, 0.002;   # throttle: keep it in flight
    }
    close $s;
    printf {$wr} "%d %d\n", ($cl // 0), $got - ($hl // 0);
    close $wr;
    POSIX::_exit(0);
}
close $wr;

our @keep;
my $f = Feersum->new();
$f->use_socket($sock);
$f->set_keepalive(1);
$f->read_timeout(60 * TIMEOUT_MULT);
$f->write_timeout(60 * TIMEOUT_MULT);
$f->psgi_request_handler(sub {
    return sub {
        my $respond = shift;
        open my $fh, '<', $file or die "open: $!";
        my $w = $respond->([200, ['Content-Type' => 'application/octet-stream',
                                  'Content-Length' => $size]]);
        push @keep, $w;
        $w->sendfile($fh);
    };
});

my ($active_at_shutdown, $drained);
# Shut down when the transfer is demonstrably in flight, rather than after a
# fixed delay and hoping.  On a loaded CI runner the client had not connected
# within the delay, so active_conns was 0 and the test asserted about a
# shutdown that raced nothing - it failed there while passing everywhere else.
my $sd;
$sd = EV::timer(0.2 * TIMEOUT_MULT, 0.1, sub {
    my $n = $f->active_conns;
    return unless $n >= 1;
    $active_at_shutdown = $n;
    $sd = undef;                  # one-shot, now that the race is won
    $f->graceful_shutdown(sub { $drained = 1 });
});
my $guard = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
my $cw = EV::child($client, 0, sub { EV::break() });
EV::run();

my $line = <$rd>;
close $rd;
waitpid $client, 0;
chomp $line if defined $line;
my ($cl, $received) = split q{ }, ($line // '0 0');

cmp_ok $active_at_shutdown || 0, '>=', 1,
    'shutdown was requested while the transfer was still in flight';
is $cl, $size, 'client was promised the full Content-Length';
is $received, $size,
    "in-flight sendfile completed across graceful_shutdown ($received/$size bytes)";
