#!perl
use warnings;
use strict;
use constant HARDER => $ENV{RELEASE_TESTING} ? 1 : 0;
use constant NUM_FORK => HARDER ? 4 : 2;
use constant CLIENTS => HARDER ? 30 : 4;
use Test::More tests => 4 + CLIENTS*3;
use utf8;
use lib 't'; use Utils;
use File::Spec::Functions 'rel2abs';

use_ok 'Feersum::Runner';

my (undef, $port) = get_listen_socket();

my $cv;
my $test = 0;

sub simple_get {
    my ($port, $n) = @_;
    $cv->begin;
    my $cli; $cli = simple_client GET => "/?q=$n",
        name => "client $n",
        sub {
            my ($body,$headers) = @_;
            is($headers->{Status}, 200, "client $n: http success") or diag($headers->{Reason});
            like $body, qr/^Hello customer number 0x[0-9a-f]+$/, "client $n: looks good";
            $cv->end;
            undef $cli;
        };
}

note(my $app_path = rel2abs('eg/app.feersum'));
my $pid = fork;
die "can't fork: $!" unless defined $pid;
if (!$pid) {
    require POSIX;
    eval {
        my $runner = Feersum::Runner->new(
            listen => ["localhost:$port"],
            server_starter => 1,
            app_file => $app_path,
            pre_fork => NUM_FORK,
            quiet => 1,
        );
        $runner->run();
    };
    POSIX::exit(0);
}

select undef, undef, undef, 0.25; # sleep a bit to give the server time to start

$cv = AE::cv;
simple_get($port, $_) for (1..CLIENTS);
$cv->recv;
pass "killing";
kill 3, $pid; # QUIT
pass "killed";
waitpid $pid, 0;
pass "reaped";
