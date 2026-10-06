#!perl
# getline() must survive a tied $/ whose FETCH consumes the reader mid-call:
# it yields undef, not a SEGV.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
plan tests => 5;

{
    package R5::StealingRS;
    sub TIESCALAR { bless { cb => $_[1] } }
    sub FETCH { $_[0]->{cb}->() }
    sub STORE {}
}

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
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $in = $env->{'psgi.input'};
        my $stole = 0;
        my $tied;
        # steal on the first FETCH: the FETCH count varies by perl version
        tie $tied, 'R5::StealingRS', sub {
            unless ($stole) {
                $stole = 1;
                my $b = '';
                $in->read($b, 1_000_000);
            }
            return 5;
        };
        local $/ = \$tied;
        my $line = eval { $in->getline };
        my $err = $@;
        my $after = eval { $in->read(my $rest, 100) };
        open my $out, '>', "$dir/state" or die $!;
        print {$out} join(' ',
            'survived=1',
            'line=' . (defined $line ? 'DEF' : 'undef'),
            'err=' . ($err ? 'ERR' : 'ok'),
            'after=' . (defined $after ? $after : 'undef'),
        ), "\n";
        close $out;
        return [200, ['Content-Type' => 'text/plain',
                      'Connection' => 'close'], ['done']];
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

my $body = "line1\nline2\nline3\n";
my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
    Proto => 'tcp', Timeout => 10 * TMULT) or die "connect: $!";
$s->autoflush(1);
print {$s} "POST / HTTP/1.1\015\012Host: x\015\012Content-Length: "
         . length($body) . "\015\012Connection: close\015\012\015\012$body";
my $resp = '';
$resp .= $_ while sysread($s, $_, 65536);
close $s;

my $state = do {
    open my $fh, '<', "$dir/state" or die "no state file: $!";
    local $/; <$fh>;
};

like $state, qr/survived=1/, 'handler survived a consuming $/-FETCH';
like $state, qr/line=undef err=ok/, 'getline yields undef, no error';
like $state, qr/after=0/, 'follow-up read sees EOF';
like $resp, qr/^HTTP\/1\.1 200 .*done$/s, 'normal response after the ordeal';
