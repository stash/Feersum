#!perl
# A delayed second $responder call must route through Feersum::DIED like the
# 3-elem path, not croak with no G_EVAL above it.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
plan tests => 4;

my $dir = tempdir(CLEANUP => 1);

my ($lsn, $port) = get_listen_socket();
ok $lsn, "listen on $port";

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    close $lsn;
    select undef, undef, undef, 0.5 * TMULT;
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto => 'tcp', Timeout => 10 * TMULT);
    if (!$c) {
        open my $out, '>', "$dir/status" or POSIX::_exit(9);
        print {$out} "FAIL connect: $!\n";
        close $out;
        POSIX::_exit(1);
    }
    syswrite($c, "GET / HTTP/1.1\015\012Host: x\015\012Connection: close\015\012\015\012");
    my $got = '';
    $got .= $_ while sysread($c, $_, 65536);
    open my $out, '>', "$dir/resp" or POSIX::_exit(9);
    print {$out} $got;
    close $out;
    open $out, '>', "$dir/status" or POSIX::_exit(9);
    print {$out} "OK\n";
    close $out;
    POSIX::_exit(0);
}

my $s = Feersum->new();
$s->use_socket($lsn);
my $died_msg = '';
{
    no warnings 'redefine';
    *Feersum::DIED = sub { $died_msg = $_[0] };
}
$s->psgi_request_handler(sub {
    return sub {
        my $responder = shift;
        my $w = $responder->([200, ['Content-Type' => 'text/plain']]);
        $w->write('hi');
        my $t; $t = AE::timer 0.5 * TMULT, 0, sub {
            undef $t;
            $responder->([200, ['Content-Type' => 'text/plain']]);
            $w->close;
        };
    };
});
my $cv = AE::cv;
my $cw = AE::child($pid, sub { $cv->send });
my $t = AE::timer 8 * TMULT, 0, sub { kill 'KILL', $pid; $cv->send };
$cv->recv;
waitpid($pid, 0);

my $resp = do {
    open my $fh, '<', "$dir/resp" or die "no resp file: $!";
    local $/; my $c = <$fh>; close $fh;
    $c;
};
my $status = do {
    open my $fh, '<', "$dir/status" or die "no status file: $!";
    local $/; <$fh>;
};

is $status, "OK\n", 'client finished';
like $died_msg, qr/after the response had already started/,
    'second $respond routed through DIED';
like $resp, qr/^HTTP\/1\.1 200 .*2\015\012hi\015\0120\015\012\015\012$/s,
    'first response terminated (chunked hi)';
