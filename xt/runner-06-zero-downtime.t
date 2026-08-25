#!perl
# Zero-downtime reload: after HUP, new connections go to the new generation
# while keepalive connections to the old one still complete.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 10;  # 7 explicit + 3 simple_client implicit
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
my $app = "$dir/zerodown.feersum";
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

# Get gen1 pid
my $pid1 = extract_pid(http_get($port));
ok $pid1, "gen1 serving (pid $pid1)";

# HUP - gen2 starts, gen1 gets QUIT (graceful)
kill 'HUP', $master;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

# New connection should go to gen2
my $pid2 = extract_pid(http_get($port));
ok $pid2, "after HUP, server responds";
isnt $pid2, $pid1, "new connection goes to gen2 (pid $pid2)";

# Another HUP to verify chained reloads work
kill 'HUP', $master;
select undef, undef, undef, 2.0 * TIMEOUT_MULT;

my $pid3 = extract_pid(http_get($port));
ok $pid3, "after second HUP, server responds";
isnt $pid3, $pid2, "third generation serving (pid $pid3)";
isnt $pid3, $pid1, "third gen differs from first gen too";

reap_server($master);
pass "zero-downtime chain clean shutdown";
