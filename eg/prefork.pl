#!/usr/bin/env perl
# Prefork server - N worker processes sharing one listen socket.
# Usage: perl eg/prefork.pl [port] [workers]
use strict;
use warnings;
use Feersum;
use EV;
use IO::Socket::INET;
use Socket qw(SOMAXCONN);
use POSIX qw(_exit);

my $port    = shift || 5000;
my $workers = shift || 4;

my $socket = IO::Socket::INET->new(
    LocalAddr => "0.0.0.0:$port",
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "Cannot listen on port $port: $!\n";

print "Feersum prefork on http://localhost:$port/ ($workers workers)\n";

my @pids;
for my $i (1 .. $workers) {
    my $pid = fork // die "fork: $!";
    if ($pid == 0) {
        # Worker process
        my $feer = Feersum->new();
        $feer->use_socket($socket);
        $feer->set_keepalive(1);

        $feer->request_handler(sub {
            $_[0]->send_response(200, ['Content-Type' => 'text/plain'],
                                 \"Hello from worker $i (PID $$)\n");
        });

        my $quit = EV::signal QUIT => sub {
            $feer->graceful_shutdown(sub { EV::break });
        };

        EV::run;
        _exit(0);
    }
    push @pids, $pid;
    print "  worker $i: PID $pid\n";
}

# Parent: wait for children, forward signals
$SIG{QUIT} = $SIG{INT} = $SIG{TERM} = sub {
    kill QUIT => @pids;
};

waitpid($_, 0) for @pids;
print "All workers exited.\n";
