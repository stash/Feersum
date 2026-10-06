#!perl
# A Content-Length above SSIZE_MAX must be rejected even when max_body_len
# allows it: a cast to negative would dispatch a truncated body as complete.
use warnings;
use strict;
use Config;
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use EV;
use Feersum;

plan skip_all => 'needs 64-bit UV' if $Config{uvsize} < 8;
plan tests => 3;

my $HUGE_CL = '9223372036854775808'; # SSIZE_MAX+1 on 64-bit
my $HUGE_MAX = '18446744073709551615'; # SIZE_MAX

sub post_status {
    my ($maxbl, $cl, $body) = @_;
    my ($listen, $port) = get_listen_socket();
    my $server = fork();
    die "fork: $!" unless defined $server;
    if (!$server) {
        $SIG{QUIT} = 'DEFAULT';
        my $f = Feersum->new_instance();
        $f->max_body_len($maxbl) if defined $maxbl;
        $f->psgi_request_handler(sub {
            my $in = $_[0]->{'psgi.input'};
            1 while $in->read(my $chunk, 65536);
            [200, ['Content-Type' => 'text/plain'], ['ok']];
        });
        $f->use_socket($listen);
        my $life = EV::timer(30, 0, sub { POSIX::_exit(2) });
        EV::run();
        POSIX::_exit(3);
    }
    close $listen;
    select undef, undef, undef, 0.3;
    my $status = 'NO-RESPONSE';
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 10);
    if ($s) {
        syswrite $s, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: $cl\r\n"
                   . "Connection: close\r\n\r\n$body";
        my $raw = '';
        while (1) { my $n = sysread $s, my $z, 4096; last if !$n; $raw .= $z }
        close $s;
        ($status) = $raw =~ m{^(HTTP/1\.[01] \d+)};
    }
    reap_server($server);
    return $status;
}

is post_status($HUGE_MAX, $HUGE_CL, 'hello'), 'HTTP/1.1 413',
    'CL above SSIZE_MAX is rejected even with max_body_len at SIZE_MAX';
is post_status(1024 * 1024, $HUGE_CL, 'hello'), 'HTTP/1.1 413',
    'control: same CL with a 1MB cap is still 413';
is post_status(undef, 5, 'hello'), 'HTTP/1.1 200',
    'sanity: ordinary Content-Length still works';
