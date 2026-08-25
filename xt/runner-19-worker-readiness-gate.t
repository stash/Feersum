#!perl
# In pre_fork hot_restart the generation signals USR2 "ready" only after its
# workers report in; if they die at startup the reload fails and the master
# keeps the running generation.
# Author-only: the readiness handshake is a startup race a loaded smoker loses.
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
    plan skip_all => 'needs a POSIX fork' unless $Config::Config{d_fork}
        || eval { require Config; $Config::Config{d_fork} };
}
plan tests => 4;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir  = tempdir(CLEANUP => 1);
my $flag = "$dir/break_after_fork";   # present => a worker's after_fork dies
my $app  = "$dir/gen.feersum";
open my $ah, '>', $app or die $!;
print $ah <<'APP';
sub { $_[0]->send_response(200, ["Content-Type"=>"text/plain"], \"gen-ok") }
APP
close $ah;

my (undef, $port) = get_listen_socket();

sub serves {
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 2 * TIMEOUT_MULT) or return 0;
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 3 * TIMEOUT_MULT;
        print $s "GET / HTTP/1.0\r\n\r\n";
        local $/;
        $r = <$s> // '';
        alarm 0; 1;
    };
    alarm 0; close $s;
    return $r =~ /gen-ok/ ? 1 : 0;
}

my $logf = "$dir/master.log";
my $master = fork // die "fork: $!";
if (!$master) {
    open STDOUT, '>', "$dir/master.out";
    open STDERR, '>', $logf;
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["127.0.0.1:$port"], app_file => $app,
            hot_restart => 1, pre_fork => 2, quiet => 1,
            startup_timeout => 2 * TIMEOUT_MULT,
            # per-worker, so gen 1 comes up clean and only the reload's do not
            after_fork => sub { die "after_fork boom\n" if -e $flag },
        )->run;
    };
    POSIX::_exit(0);
}

my $up = 0;
for (1 .. 80) { select undef, undef, undef, 0.2 * TIMEOUT_MULT; last if $up = serves() }
ok $up, 'gen 1 (pre_fork) is serving';

# Break the next generation's workers, then reload.
open my $f, '>', $flag or die $!; close $f;
kill 'HUP', $master;

# The reload's workers cannot come up, so the generation must fail and the
# master keep the old one rather than retire it.
my $kept = 0;
for (1 .. 120) {
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
    if (open my $lh, '<', $logf) { local $/; my $l = <$lh> // ''; close $lh;
        $kept = 1 if $l =~ /keeping old/; }
    last if $kept;
}
ok $kept, 'failed reload is rolled back (master keeps the old generation)';

ok serves(), 'the old generation is still serving after the failed reload';
ok +(waitpid($master, POSIX::WNOHANG()) == 0), 'master is still alive';

kill 'QUIT', $master if kill 0, $master;
for (1 .. 60) { select undef, undef, undef, 0.1 * TIMEOUT_MULT;
    last if waitpid($master, POSIX::WNOHANG()) > 0 }
kill 'KILL', $master if kill 0, $master;
