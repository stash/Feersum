#!/usr/bin/env perl
# Feersum native app with prefork for benchmarking
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use Feersum;
use Socket qw(SOMAXCONN);
use IO::Socket::INET;
use EV;
use POSIX qw(_exit);

my $port = $ARGV[0] || 5001;
my $forks = $ARGV[1] || 3;

my $socket = IO::Socket::INET->new(
    LocalAddr => "localhost:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "Cannot create socket: $!";

# Fork workers
my @pids;
for my $i (1 .. $forks) {
    my $pid = fork;
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Child process
        EV::default_loop()->loop_fork;

        my $feersum = Feersum->new();
        $feersum->use_socket($socket);
        $feersum->set_keepalive(1);

        my $body = "Hello, World!";
        $feersum->request_handler(sub {
            my $req = shift;
            $req->send_response(200, ['Content-Type' => 'text/plain'], \$body);
        });

        EV::run;
        _exit(0);
    }
    push @pids, $pid;
}

print "Feersum native prefork server on http://127.0.0.1:$port/ (workers: $forks)\n";

# Parent waits for children
$SIG{INT} = $SIG{TERM} = sub {
    kill 'QUIT', @pids;
    exit 0;
};

waitpid($_, 0) for @pids;
