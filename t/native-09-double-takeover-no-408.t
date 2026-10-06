#!perl
# The header deadline, like the read deadline, must not touch an app-owned
# socket: io() -> return_from_io() -> io() must not get an unsolicited 408.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
plan tests => 3;

$SIG{PIPE} = 'IGNORE';

my $dir = tempdir(CLEANUP => 1);
my ($lsn, $port) = get_listen_socket();
ok $lsn, "listen on $port";

# status file, not exit code: the EV loop reaps mid-run children
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    close $lsn;
    my $fail = sub {
        open my $out, '>', "$dir/status" or POSIX::_exit(9);
        print {$out} "FAIL $_[0]\n";
        close $out;
        POSIX::_exit(1);
    };
    select undef, undef, undef, 0.5 * TMULT;
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto => 'tcp', Timeout => 5 * TMULT) or $fail->("connect: $!");
    syswrite($c, "GET / HTTP/1.1\015\012Host: x\015\012\015\012");
    # header_timeout is a fixed 1s, so 2s of silence (not TMULT-scaled) proves no 408
    my $got = '';
    my $deadline = time() + 2;
    while (time() < $deadline) {
        my $rin = '';
        vec($rin, fileno($c), 1) = 1;
        last unless select($rin, undef, undef, $deadline - time());
        my $buf;
        my $r = sysread($c, $buf, 65536);
        if (!$r) { $fail->('early eof'); }
        $got .= $buf;
    }
    if (length $got) { $fail->("early bytes: $got"); }
    my $fin = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5 * TMULT;
        $fin .= $_ while sysread($c, $_, 65536);
        alarm 0;
    };
    if ($fin !~ /^HTTP\/1\.1 200 .*^manual$/ms) { $fail->("bad tail: $fin"); }
    open my $out, '>', "$dir/status" or POSIX::_exit(9);
    print {$out} "OK\n";
    close $out;
    POSIX::_exit(0);
}

my $s = Feersum->new();
$s->header_timeout(1);
$s->use_socket($lsn);
my ($took_twice, $held);
$s->request_handler(sub {
    my $req = shift;
    my $h1 = $req->io;
    $req->return_from_io($h1);
    $held = $req->io;
    $took_twice = 1;
});
my $cv = AE::cv;
my $t = AE::timer 2 + 1 * TMULT, 0, sub {   # after the child's 2s silence window
    if ($held) {
        $held->autoflush(1);
        print {$held} "HTTP/1.1 200 OK\015\012Content-Length: 6\015\012"
                     . "Connection: close\015\012\015\012manual";
        close $held;
    }
    $cv->send;
};
$cv->recv;
waitpid($pid, 0);

my $status = do {
    open my $fh, '<', "$dir/status" or die "no status file: $!";
    local $/; <$fh>;
};

ok $took_twice, 'server took the socket over twice';
is $status, "OK\n", 'no 408 during takeover, app socket still usable';
