#!perl
# A second start on a live UNIX socket must fail loudly instead of silently
# splitting traffic between the old server (deleted inode) and the new one.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::UNIX;
use File::Temp qw(tempdir);
use POSIX ();

plan tests => 2;

my $dir = tempdir(DIR => '/tmp', CLEANUP => 1);
my $path = "$dir/feer.sock";
my $app = "$dir/app.feersum";
open my $fh, '>', $app or die "open $app: $!";
print {$fh} q{sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],"one") }};
close $fh or die "close $app: $!";

sub unix_get {
    my $s = IO::Socket::UNIX->new(Peer => $path,
        Timeout => 3 * TIMEOUT_MULT) or return undef;
    print {$s} "GET /x HTTP/1.0\015\012\015\012";
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 3 * TIMEOUT_MULT;
        while (sysread($s, my $b, 4096)) { $r .= $b }
        alarm 0;
    };
    alarm 0;
    close $s;
    return $r;
}

my $first = fork // die "fork: $!";
if (!$first) {
    open STDOUT, '>', '/dev/null' or POSIX::_exit(2);
    open STDERR, '>', "$dir/first.log" or POSIX::_exit(2);
    require Feersum::Runner;
    Feersum::Runner->new(listen => [$path], app_file => $app)->run();
    POSIX::_exit(0);
}

my $ready = 0;
for (1 .. 30 * TIMEOUT_MULT) {
    my $r = unix_get();
    if (defined $r && $r =~ m{^HTTP/1\.[01] 200}) { $ready = 1; last }
    select undef, undef, undef, 0.2;
}
unless ($ready) {
    kill 'KILL', $first;
    waitpid $first, 0;
    die 'first server never came up';
}

my $second = fork // die "fork: $!";
if (!$second) {
    open STDOUT, '>', '/dev/null' or POSIX::_exit(2);
    open STDERR, '>', "$dir/second.log" or POSIX::_exit(2);
    require Feersum::Runner;
    my $rc = eval {
        Feersum::Runner->new(listen => [$path], app_file => $app)->run();
        0;
    };
    if ($@) {
        print STDERR $@;
        POSIX::_exit(3);
    }
    POSIX::_exit($rc);
}

my $exited = 0;
my $status = 0;
for (1 .. 25 * TIMEOUT_MULT) {
    my $kid = waitpid $second, POSIX::WNOHANG();
    if ($kid > 0) { $exited = 1; $status = $?; last }
    select undef, undef, undef, 0.2;
}
if (!$exited) {
    kill 'KILL', $second;
    waitpid $second, 0;
    $status = -1;
}

open my $efh, '<', "$dir/second.log" or die "open second.log: $!";
my $err = do { local $/; <$efh> };

is(($status >> 8), 3, 'second start on a live socket exits loudly')
    or diag "second server status: $status (still running means traffic split)";
like $err, qr/live server/, 'the error names the live server'
    or diag "second.log: $err";

kill 'QUIT', $first;
eval {
    local $SIG{ALRM} = sub { die "reap timeout\n" };
    alarm 10 * TIMEOUT_MULT;
    waitpid $first, 0;
    alarm 0;
};
alarm 0;
if (kill 0, $first) { kill 'KILL', $first; waitpid $first, 0 }
