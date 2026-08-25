#!perl
# A fork() failure while restarting a dead hot_restart generation must arm a
# retry, not croak inside an EV watcher (EV discards the exception and leaves
# the master alive with nothing serving).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

BEGIN {
    plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
    plan skip_all => 'needs a POSIX fork'       unless $Config::Config{d_fork}
        || eval { require Config; $Config::Config{d_fork} };
}
plan tests => 4;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir  = tempdir(CLEANUP => 1);
my $flag = "$dir/forkfail";
my $app  = "$dir/gen.feersum";
my $gen_pid_file = "$dir/gen.pid";
open my $ah, '>', $app or die $!;
# The app file is loaded BY the generation child, so $$ there identifies it.
# pgrep is not installed in every CI image, and a missed kill leaves an orphan
# holding the harness's pipe open - prove then waits for EOF forever.
print $ah <<"APP";
if (open my \$p, '>', '$gen_pid_file') { print {\$p} "\$\$\\n"; close \$p }
sub { \$_[0]->send_response(200,["Content-Type"=>"text/plain"],\\"gen-ok") }
APP
close $ah;

my (undef, $port) = get_listen_socket();

sub serves {
    # connect() succeeds against a bound-but-unaccepting port, so this read
    # must be bounded - blocking here is the very state under test.
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 2 * TIMEOUT_MULT) or return 0;
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 3 * TIMEOUT_MULT;
        print $s "GET / HTTP/1.0\r\n\r\n";
        local $/;
        $r = <$s> // '';
        alarm 0;
        1;
    };
    alarm 0;
    close $s;
    return $r =~ /gen-ok/ ? 1 : 0;
}


my $master = fork // die "fork: $!";
if (!$master) {
    # Never hold the harness's stdout: a leaked descendant keeps the pipe open
    # and prove waits for EOF forever instead of failing.
    open STDOUT, '>', "$dir/master.out";
    open STDERR, '>', "$dir/master.log";
    # Make fork() fail on demand.  Installed here, in the child, so the
    # override is in place before Feersum::Runner's fork calls run.
    {
        no warnings qw(redefine once);
        *CORE::GLOBAL::fork = sub { -e $flag ? undef : CORE::fork() };
    }
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["127.0.0.1:$port"], app_file => $app,
            hot_restart => 1, quiet => 1,
            startup_timeout => 5 * TIMEOUT_MULT,
        )->run;
    };
    POSIX::_exit(0);
}

my $up = 0;
for (1 .. 60) { select undef, undef, undef, 0.2 * TIMEOUT_MULT; last if $up = serves() }
ok $up, 'hot_restart: generation 1 is serving';

my $genpid;
for (1 .. 40) {
    if (open my $gh, '<', $gen_pid_file) {
        chomp($genpid = <$gh> // q{});
        close $gh;
        last if $genpid && $genpid =~ /^\d+$/;
    }
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
}
$genpid = undef unless $genpid && $genpid =~ /^\d+$/;
ok $genpid, 'the generation child reported its pid';

# Arm the fork failure, then kill the serving generation so the reap watcher
# has to fork a replacement - and cannot.
open my $fh, '>', $flag or die $!;
close $fh;
kill 'KILL', $genpid if $genpid;

my $exited = 0;
for (1 .. 80) {
    select undef, undef, undef, 0.25 * TIMEOUT_MULT;
    if (waitpid($master, POSIX::WNOHANG()) > 0) { $exited = 1; last }
}
ok $exited, 'master exits when it cannot fork a replacement, instead of '
          . 'looping forever with nothing serving';
ok !serves(), 'nothing is left serving the port';

unless ($exited) {
    kill 'KILL', $master;
    waitpid $master, 0;
}
kill 'KILL', $genpid if $genpid && kill(0, $genpid);
