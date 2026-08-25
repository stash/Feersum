#!perl
# #8: the hot_restart generation installed QUIT/TERM/INT handlers but no HUP, so
# a HUP delivered to the generation (a process-group HUP, or a mis-aimed kill)
# terminated it by default disposition.  It now ignores HUP, as the cold-start
# supervisor does; only the master acts on it (to reload).
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
        local $/; $r = <$s> // '';
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
            hot_restart => 1, quiet => 1, startup_timeout => 5 * TIMEOUT_MULT,
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

# HUP straight to the generation: it must survive, not die by default action.
kill 'HUP', $gp if $gp;
select undef, undef, undef, 1.5 * TIMEOUT_MULT;
ok +($gp && kill 0, $gp), 'the generation survives a SIGHUP (ignored, not fatal)';
ok serves(), 'and it is still serving the same generation';

kill 'QUIT', $master if kill 0, $master;
for (1 .. 40) { select undef, undef, undef, 0.1 * TIMEOUT_MULT;
    last if waitpid($master, POSIX::WNOHANG()) > 0 }
kill 'KILL', $master if kill 0, $master;
kill 'KILL', $gp if $gp && kill 0, $gp;
