#!perl
# psgi.input->read() reports EOF as 0 on H2 as on H1; a UNIX-domain listener
# does not report SERVER_NAME=localhost SERVER_PORT=80; preload_app => 0
# without app_file is refused rather than silently preloading the coderef.
use warnings;
use strict;
use Test::More;
use IO::Socket::UNIX;
use File::Temp qw(tempdir);
use lib 't'; use Utils;

use Feersum;
use Feersum::Runner;

plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
plan tests => 9;  # 8 explicit + 1 simple_client implicit

my $dir = tempdir(CLEANUP => 1);

###############################################################################
# 1. UNIX listener reports an honest SERVER_NAME/SERVER_PORT
###############################################################################
{
    my $path = "$dir/sn.sock";
    my $sock = IO::Socket::UNIX->new(Local => $path, Listen => 5)
        or plan skip_all => "cannot create UNIX socket: $!";
    $sock->blocking(0);

    my $evh = Feersum->new_instance();
    $evh->use_socket($sock);

    my ($name, $port);
    $evh->psgi_request_handler(sub {
        my $env = shift;
        ($name, $port) = @$env{qw(SERVER_NAME SERVER_PORT)};
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });

    my $pid = fork // die "fork: $!";
    if (!$pid) {
        select undef, undef, undef, 0.3;
        my $c = IO::Socket::UNIX->new(Peer => $path);
        if ($c) { print {$c} "GET / HTTP/1.0\r\n\r\n"; sysread($c, my $r, 4096) }
        POSIX::_exit(0);
    }
    my $cv = AE::cv;
    my $t  = AE::timer(5, 0, sub { $cv->send });
    my $cw = AE::child($pid, sub { $cv->send });
    $cv->recv;
    waitpid $pid, 0;

    isnt $name, 'localhost',
        "UNIX listener SERVER_NAME is not the TCP default";
    is $name, 'unix', "... it is 'unix', matching REMOTE_ADDR on AF_UNIX";
    is $port, 0, "UNIX listener SERVER_PORT is 0, not 80";
    $evh->unlisten;
}

###############################################################################
# 2. preload_app => 0 without app_file is refused, not silently ineffective
###############################################################################
{
    my $r = Feersum::Runner->new(
        listen => ['127.0.0.1:0'], pre_fork => 2, preload_app => 0,
        quiet => 1, app => sub { $_[0]->send_response(200, [], []) },
    );
    ok $r, "constructed runner with app + preload_app => 0";
    my $ok = eval { $r->run; 1 };
    my $err = $@ || '';
    ok !$ok, "run() refuses preload_app => 0 without app_file";
    like $err, qr/preload_app/, "... and the message names the option";
}

###############################################################################
# 3. psgi.input EOF on a bodyless request reports 0, not undef/EAGAIN
###############################################################################
{
    my ($sock, $port) = get_listen_socket();
    my $evh = Feersum->new_instance();
    $evh->use_socket($sock);

    my ($ret, $errno);
    $evh->psgi_request_handler(sub {
        my $env = shift;
        $! = 0;
        $ret = $env->{'psgi.input'}->read(my $buf, 4096);
        $errno = $! + 0;
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });

    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/', port => $port, timeout => 5,
        sub { $cv->send; undef $cli };
    $cv->recv;

    is $ret, 0, "psgi.input read() at end of input returns 0";
    is $errno, 0, "... and leaves errno clear";
    $evh->unlisten;
}
