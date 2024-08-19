#!perl
use warnings;
use strict;
use Test::More;
use utf8;
use lib 't'; use Utils;

BEGIN {
    plan skip_all => 'no applicable on win32'
        if $^O eq 'MSWin32';
    plan skip_all => "Need Test::SharedFork >=0.25 to run this test"
        unless eval 'require Test::SharedFork; $Test::SharedFork::VERSION >= 0.25';
}

use Feersum::Runner;
use Test::SharedFork;
use IO::Socket::UNIX;
use File::Temp 'tempfile';

(undef, my $sock_path) = tempfile(uc'xxxx',qw/TMPDIR 1 SUFFIX .sock UNLINK 1/);

plan skip_all => "can't create tmp socket path"
    unless $sock_path;

unlink $sock_path;

plan tests => 8;

pass 'using sock path '.$sock_path;

my $pid = fork();
if ($pid == 0) { # child
    eval {
        my $runner = Feersum::Runner->new(
            listen => [$sock_path],
            app => sub {
                pass 'got request';
                shift->send_response(200, [], []);
            }
        );
        ok $runner, "got a runner";
        $runner->run;
    };
    warn $@ if $@;
} elsif ($pid) { # parent
    my $retry = 100; # wait socket file, up to 10 sec
    while () {
        die 'no server socket' unless $retry--;
        select undef, undef, undef, 0.1;
        last if -S $sock_path;
    }
    my $socket = IO::Socket::UNIX->new(
        Peer => $sock_path,
        Type => SOCK_STREAM,
    ) or warn $!;
    ok $socket, 'client ok';
    ok $socket->blocking(0), 'unblock socket';
    my $cv = AE::cv;
    $cv->begin;
    my $hdl; $hdl = AnyEvent::Handle->new(
        fh => $socket,
        on_error => sub {
            $hdl->destroy;
            $cv->send;
        },
        timeout => 5
    );
    $hdl->push_write("GET / HTTP/1.1\015\012\015\012");
    $hdl->push_read(line => sub {
        is $_[1], 'HTTP/1.1 200 OK', 'got reply';
        $cv->send;
    });
    $cv->recv;
    undef $hdl;
    pass 'server killing';
    kill 3, $pid; # QUIT
    waitpid $pid, 0;
    pass 'server killed';
} else {
    die $!;
};
