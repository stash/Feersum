#!perl
use warnings;
use strict;
use constant PARALLEL => 15;
use Test::More qw/no_plan/;
use lib 't'; use Utils;
use POSIX ();

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";

my $APP = <<'EOAPP';
    my $app = sub {
        my $env = shift;
        return [
            200,
            ['Content-Type' => 'text/plain'],
            ['Hello',' ','World']
        ];
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' || diag $@;

POSIX::setsid;
my $ppid = $$;
my $pid = fork();
if (!defined($pid)) {
    die "can't fork: $!";
}
elsif ($pid == 0) {
    my $evh = Feersum->new();
    {
        no warnings 'redefine';
        *Feersum::DIED = sub {
            my $err = shift;
            warn "DIED: $err";
            kill 9, -$ppid;
            POSIX::_exit(2);
        };
    }
    $evh->use_socket($socket);
    $evh->psgi_request_handler($app);
    my $quit; $quit = AE::signal 'QUIT', sub {
        $evh->graceful_shutdown();
    };
    AE::cv->recv;
    scope_guard { POSIX::_exit(0) };
}

sleep 1;

my $cv = AE::cv;
my $requests = 0;
my $responses = 0;
my $total_latency = 0.0;

sub cli ($);
sub cli ($) {
    my $n = shift;
#     diag "($n) starting req";
    $cv->begin;
    my $r_start = AE::time;
    my $h; $h = simple_client GET => '/',
        name => "($n)",
    sub {
        my ($body, $headers) = @_;
        scope_guard { $cv->end };
#         is $headers->{'Status'}, 200, "($n) Response OK";
#         is $headers->{'content-type'}, 'text/plain', "... ($n) is text";
#         is $body, 'Hello World', "... ($n) correct body";
#         is $headers->{'content-length'}, 11;
        $total_latency += AE::time - $r_start;
        $cv->croak("extra crap!") if length($h->{rbuf});
        undef $h;
        if ($headers->{'Status'}) {
            $responses++;
            cli $n;
        }
    };
    $requests++;
}

for my $n (1 .. PARALLEL) {
    cli $n;
}

my $t; $t = AE::timer 15, 0, sub {
    $cv->croak("time's up!");
};

my $started = AE::time();
eval { $cv->recv };
diag $@ if $@;
my $finished = AE::time();

pass "clients done, waitpid";
kill 9, $pid;
waitpid $pid, 0;

my $taken = $finished-$started;
print "resp/sec:   ".sprintf('%0.4f r/s',$responses/$taken)."\n";
print "overall/req ".sprintf('%0.2f ms/r',$taken*1000.0/$responses)."\n";
print "latency/req ".sprintf('%0.2f ms/r',$total_latency*1000.0/$responses)."\n";
pass "all done";
