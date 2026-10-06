#!perl
# A reader poll_cb installed outside the handler may close its own handle
# mid-call; the connection must survive with no watcher or timer holding a ref.
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
plan tests => 5;

my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
ok $listen, "listen on $port";

my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    open STDERR, '>', "$dir/server.log" or die $!;
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->linger_timeout(0);   # no linger refs: close responses free fast
    my $stashed;
    my ($install, $armed);
    $f->psgi_request_handler(sub {
        my $env = shift;
        # arm from the handler (once), so the installer never fires ahead of the
        # stashed input - a startup timer races the first request on a slow box
        unless ($armed++) {
            $stashed = $env->{'psgi.input'};
            $stashed->read(my $part, 6);   # the rest stays buffered, so installing poll_cb pumps
            $install = EV::timer(0.2 * TMULT, 0, sub {
                undef $install;
                my $ran = 0;
                $stashed->poll_cb(sub {
                    my $h = shift;
                    $ran++;
                    $h->close;
                    undef $stashed;
                });
                open my $out, '>', "$dir/state.tmp" or die $!;
                print {$out} "ran=$ran\n";
                close $out;
                rename "$dir/state.tmp", "$dir/state" or die $!;  # atomic: no torn read on a slow box
            });
        }
        return [200, ['Content-Type' => 'text/plain',
                      'Connection' => 'close'], ['done']];
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

my $body = '0123456789abcdefghi';
my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
    Proto => 'tcp', Timeout => 5 * TMULT) or die "connect: $!";
print {$s} "POST / HTTP/1.1\015\012Host: x\015\012Content-Length: "
         . length($body) . "\015\012Connection: close\015\012\015\012$body";
my $resp = '';
$resp .= $_ while sysread($s, $_, 65536);
close $s;
like $resp, qr/^HTTP\/1\.1 200 .*done$/s, 'close response received';

my $state = '';
for (1 .. 100 * TMULT) {
    if (-s "$dir/state" && open my $fh, '<', "$dir/state") {
        local $/; $state = <$fh>;
        close $fh;
        last if length $state;
    }
    select undef, undef, undef, 0.05;
}
like $state, qr/ran=1/, 'deferred poll_cb ran exactly once';

my $s2 = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
    Proto => 'tcp', Timeout => 5 * TMULT);
ok $s2, 'server accepts a second connection';
if ($s2) {
    print {$s2} "GET / HTTP/1.1\015\012Host: x\015\012Connection: close\015\012\015\012";
    my $r2 = '';
    $r2 .= $_ while sysread($s2, $_, 65536);
    close $s2;
    like $r2, qr/^HTTP\/1\.1 200 /, 'second response intact';
}
