#!perl
# Stray USR1/USR2 must not kill the supervisor: the default disposition would
# take down the whole service on a logrotate-style signal.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

plan tests => 3;

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/app.feersum";
open my $fh, '>', $app or die "open $app: $!";
print {$fh} q{sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],"alive") }};
close $fh or die "close $app: $!";

my $lsn = IO::Socket::INET->new(LocalAddr => '127.0.0.1:0', Proto => 'tcp',
    Listen => 16) or die "listen: $!";
my $port = $lsn->sockport;
close $lsn;

my $m = fork // die "fork: $!";
if (!$m) {
    open STDOUT, '>', '/dev/null' or POSIX::_exit(2);
    open STDERR, '>', "$dir/stderr.log" or POSIX::_exit(2);
    require Feersum::Runner;
    Feersum::Runner->new(listen => ["127.0.0.1:$port"], app_file => $app,
        pre_fork => 1)->run();
    POSIX::_exit(0);
}

sub try_get {
    my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
        Timeout => 3 * TIMEOUT_MULT) or return undef;
    syswrite $c, "GET / HTTP/1.0\r\nHost: x\r\n\r\n";
    my $buf = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 3 * TIMEOUT_MULT;
        while (length($buf) < 4000) {
            my $n = sysread($c, my $ch, 4096);
            last unless defined $n && $n > 0;
            $buf .= $ch;
        }
        alarm 0;
    };
    alarm 0;
    close $c;
    return $buf;
}

my $ready = 0;
for (1 .. 30 * TIMEOUT_MULT) {
    my $r = try_get();
    if (defined $r && $r =~ /alive/) { $ready = 1; last }
    select undef, undef, undef, 0.2;
}
ok $ready, 'supervisor serves before the stray signals' or do {
    kill 'KILL', $m; waitpid $m, 0;
    exit 1;
};

kill 'USR1', $m;
select undef, undef, undef, 1.0 * TIMEOUT_MULT;
kill 'USR2', $m;
select undef, undef, undef, 1.0 * TIMEOUT_MULT;

my $reaped = waitpid($m, POSIX::WNOHANG());
my @tests = (
    [$reaped <= 0 && kill(0, $m), 'supervisor survives stray USR1/USR2'],
);
my $after = try_get();
push @tests, [defined($after) && $after =~ /alive/, 'service answers after stray USR1/USR2'];
ok $_->[0], $_->[1] for @tests;

kill 'QUIT', $m;
eval {
    local $SIG{ALRM} = sub { die "reap timeout\n" };
    alarm 10 * TIMEOUT_MULT;
    waitpid $m, 0;
    alarm 0;
};
alarm 0;
if (kill 0, $m) { kill 'KILL', $m; waitpid $m, 0 }
