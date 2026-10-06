#!perl
# Recycling an idle keepalive connection for a waiting accept must skip one
# whose next request has already arrived unread.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use IO::Socket::INET;
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';

my ($socket, $port) = get_listen_socket();
my $f = Feersum->new;
$f->use_socket($socket);
$f->set_drain_accept_queue(1);   # accept idle connections at once, as the BSDs do
$f->max_connections(2);
$f->set_keepalive(1);
my %slow;
$f->psgi_request_handler(sub {
    my $path = shift->{PATH_INFO};
    return [200, ['Content-Type' => 'text/plain'], ["ok $path"]] unless $path eq '/1';
    return sub {
        my $respond = shift;
        $slow{$path} = AE::timer 0.3 * TMULT, 0, sub {
            delete $slow{$path};
            $respond->([200, ['Content-Type' => 'text/plain'], ["ok $path"]]);
        };
    };
});

sub pump { my $cv = AE::cv; my $t = AE::timer $_[0], 0, sub { $cv->send }; $cv->recv }
sub client { IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port) or die "connect: $!" }

my $holder = client();      # fills the other slot and is never idle-listed
my $client = client();
pump(0.1 * TMULT);
syswrite $client, "GET /1 HTTP/1.1\r\nHost: x\r\n\r\n";
pump(0.05 * TMULT);
my $rejected = client();    # at capacity, nothing idle: accepted, closed, accept paused
pump(0.05 * TMULT);
my $waiting = client();     # queued while accept is paused
pump(0.05 * TMULT);
# once /1 completes the connection looks idle, with /2 unread in the socket
syswrite $client, "GET /2 HTTP/1.1\r\nHost: x\r\n\r\n";

$client->blocking(0);
my ($got, $eof, $deadline) = ('', 0, time + 5 * TMULT);
while (!$eof && time < $deadline) {
    pump(0.05);
    while (1) {
        my $n = sysread $client, my $buf, 65536;
        last unless defined $n;
        if (!$n) { $eof = 1; last }
        $got .= $buf;
    }
    last if (() = $got =~ m{HTTP/1\.1 200}g) >= 2;
}
is_deeply [ $got =~ m{ok (/\d)}g ], ['/1', '/2'],
    'a connection with a request in flight is not recycled for a waiting accept';
ok !$eof, 'that connection stays open';
done_testing;
