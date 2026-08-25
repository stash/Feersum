#!perl
# A hot_restart generation and its workers drain and exit when the master dies
# (crash, SIGKILL, OOM) instead of running on orphaned with the listen socket.
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
plan tests => 3;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir     = tempdir(CLEANUP => 1);
my $genpidf = "$dir/gen.pid";
my $app     = "$dir/gen.feersum";
open my $ah, '>', $app or die $!;
# The generation child loads this, so $$ here is the generation pid.
print $ah <<"APP";
if (open my \$p, '>', '$genpidf') { print {\$p} "\$\$\\n"; close \$p }
sub { \$_[0]->send_response(200, ["Content-Type"=>"text/plain"], \\"gen-ok") }
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

my $master = fork // die "fork: $!";
if (!$master) {
    open STDOUT, '>', "$dir/master.out";
    open STDERR, '>', "$dir/master.log";
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["127.0.0.1:$port"], app_file => $app,
            hot_restart => 1, quiet => 1,
            graceful_timeout => 2 * TIMEOUT_MULT,
            startup_timeout  => 5 * TIMEOUT_MULT,
        )->run;
    };
    POSIX::_exit(0);
}

my $up = 0;
for (1 .. 80) { select undef, undef, undef, 0.2 * TIMEOUT_MULT; last if $up = serves() }
ok $up, 'hot_restart generation is serving';

my $gp;
for (1 .. 40) {
    if (open my $g, '<', $genpidf) { chomp($gp = <$g> // ''); close $g;
        last if $gp && $gp =~ /^\d+$/; }
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
}
$gp = undef unless $gp && $gp =~ /^\d+$/;

# Crash the master.  The generation must notice and drain+exit.
kill 'KILL', $master;
waitpid $master, 0;

# Wait for the generation to release the listen socket, probed by binding it:
# a kill-0 check is fooled by the zombie a container's non-reaping PID 1 leaves
# behind, while a drained generation, zombie or not, has closed its listen fd.
my $released = 0;
for (1 .. 150) {
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
    my $probe = IO::Socket::INET->new(LocalAddr => '127.0.0.1',
        LocalPort => $port, Proto => 'tcp', Listen => 1, ReuseAddr => 1);
    if ($probe) { $released = 1; close $probe; last }
}
ok $released, 'the generation releases the listen socket when the master dies (no live orphan)'
    or do {
        my $log = ''; if (open my $lh, '<', "$dir/master.log") { local $/; $log = <$lh> // ''; close $lh }
        my $st = 'n/a'; if (open my $s, '<', "/proc/$gp/stat") { $st = <$s> // ''; close $s }
        diag "port still held; gen $gp /proc stat: $st\nmaster.log tail:\n" . substr($log, -1000);
    };
ok !serves(), 'nothing is left serving the port';

kill 'KILL', $gp if $gp && kill 0, $gp;
