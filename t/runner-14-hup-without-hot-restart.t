#!perl
# Without hot_restart, HUP must not kill the supervisor: the default
# disposition left the workers serving stale code on a port nothing owned.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

BEGIN { plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32' }
plan tests => 4;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/hup.feersum";
open my $ah, '>', $app or die $!;
print $ah 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"alive") }';
close $ah;

my (undef, $port) = get_listen_socket();

sub serves {
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 3 * TIMEOUT_MULT) or return 0;
    my $r = q{};
    my $ok = eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 4 * TIMEOUT_MULT;
        print {$s} "GET / HTTP/1.0\r\n\r\n";
        local $/;
        $r = <$s> // q{};
        alarm 0;
        1;
    };
    alarm 0;
    close $s;
    return ($ok && $r =~ /alive/) ? 1 : 0;
}

my $sup = fork // die "fork: $!";
if (!$sup) {
    # Never hold the harness's stdout: a leaked worker keeps the pipe open and
    # prove waits for EOF forever instead of failing.
    open STDOUT, '>', "$dir/sup.out";
    open STDERR, '>', "$dir/sup.log";
    require Feersum::Runner;
    eval {
        # No hot_restart: this is the mode where HUP used to be fatal.
        Feersum::Runner->new(listen => ["127.0.0.1:$port"], app_file => $app,
            pre_fork => 2, quiet => 1)->run;
    };
    POSIX::_exit(0);
}

my $up = 0;
for (1 .. 60) { select undef, undef, undef, 0.25 * TIMEOUT_MULT; last if $up = serves() }
ok $up, 'pre_fork supervisor is serving';

kill 'HUP', $sup;
select undef, undef, undef, 2 * TIMEOUT_MULT;

my $sup_alive = (waitpid($sup, POSIX::WNOHANG()) > 0) ? 0 : (kill(0, $sup) ? 1 : 0);
ok $sup_alive, 'SIGHUP does not kill a non-hot_restart supervisor';
ok serves(), 'and the server keeps serving';

my $log = q{};
if (open my $lh, '<', "$dir/sup.log") { local $/; $log = <$lh> // q{}; close $lh }
like $log, qr/SIGHUP ignored/, 'the operator is told why nothing reloaded';

# _start_pre_fork calls setsid(), so the supervisor leads the pool's process
# group: signalling -$sup reaps the workers too, with no pgrep dependency.
kill 'KILL', -$sup;
kill 'KILL', $sup if $sup_alive;
waitpid $sup, 0 if $sup_alive;
