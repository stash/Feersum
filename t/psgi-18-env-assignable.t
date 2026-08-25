#!perl
# Every PSGI env value, the boolean keys included, is a per-request copy the
# app may assign to; a shared immortal there dies with "Modification of a
# read-only value" and turns the request into a 500.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use Feersum;

my @KEYS = qw(
    psgi.run_once psgi.nonblocking psgi.multithread psgi.streaming
    psgi.multiprocess psgix.output.buffered
    psgix.body.scalar_refs psgix.output.guard
);
plan tests => 2 + scalar(@KEYS);

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->read_timeout(15 * TIMEOUT_MULT);
    $f->header_timeout(15 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my ($key) = ($env->{PATH_INFO} // q{}) =~ m{^/(.+)$};
        $key = q{} unless defined $key;
        my $err = q{};
        # Assign a plain value, the way middleware does.
        eval { $env->{$key} = 1; 1 } or $err = $@ // 'died';
        $err =~ s/\s+\z//;
        $err = 'OK' unless length $err;
        return [200, ['Content-Type' => 'text/plain'], [$err]];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

sub assign_result {
    my ($key) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 8 * TIMEOUT_MULT) or return 'CONNFAIL';
    syswrite $s, "GET /$key HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    my ($buf, $g) = (q{});
    while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
    close $s;
    my ($body) = $buf =~ /\r\n\r\n(.*)\z/s;
    return defined $body && length $body ? $body : 'NO-BODY';
}

is assign_result('psgi.url_scheme'), 'OK',
    'control: a string env value is assignable';

for my $k (@KEYS) {
    is assign_result($k), 'OK', "$k is a per-request copy, not a shared immortal";
}

reap_server($server);
