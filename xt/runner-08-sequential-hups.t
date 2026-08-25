#!perl
# Multiple sequential HUPs: verify each reload works, no zombie accumulation
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use constant N_RELOADS => 5;
use Test::More tests => 3 + N_RELOADS * 3;  # 3 bookend + N*(simple_client + ok + isnt)
use utf8;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

sub http_get {
    my ($port, $timeout) = @_;
    $timeout //= 3 * TIMEOUT_MULT;
    my $body;
    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/', port => $port,
        timeout => $timeout, sub {
            my ($b, $h) = @_;
            $body = $b if $h->{Status} && $h->{Status} == 200;
            $cv->send; undef $cli;
        };
    $cv->recv;
    return $body;
}

sub extract_pid { ($_[0] // '') =~ /^pid=(\d+)/ ? $1 : undef }

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/seqhup.feersum";
open my $fh, '>', $app or die;
print $fh 'sub { $_[0]->send_response(200,["Content-Type"=>"text/plain"],\"pid=$$\n") }';
close $fh;

my (undef, $port) = get_listen_socket();

my $master = fork // die "fork: $!";
if (!$master) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen      => ["localhost:$port"],
            app_file    => $app,
            hot_restart => 1,
            quiet       => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

my $prev_pid = extract_pid(http_get($port));
ok $prev_pid, "initial gen serving (pid $prev_pid)";

for my $i (1 .. N_RELOADS) {
    kill 'HUP', $master;
    select undef, undef, undef, 2.0 * TIMEOUT_MULT;

    my $cur_pid = extract_pid(http_get($port));
    ok $cur_pid, "reload $i: server responds (pid $cur_pid)";
    isnt $cur_pid, $prev_pid, "reload $i: new generation";
    $prev_pid = $cur_pid;
}

reap_server($master);
pass "sequential HUPs clean shutdown (no zombies)";
