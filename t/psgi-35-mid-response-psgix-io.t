#!perl
# psgix.io cannot be taken mid-response: reading it after streaming started
# yields undef, and a copied %$env shares the single takeover handle.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
plan tests => 7;

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
        my $p = $env->{PATH_INFO} // q{};
        if ($p eq '/stream') {
            return sub {
                my $responder = shift;
                my $w = $responder->([200, ['Content-Type' => 'text/plain',
                                                 'Content-Length' => 12]]);
                $w->write('chunk1');
                my $io = $env->{'psgix.io'};
                open my $out, '>', "$dir/stream" or die $!;
                print {$out} defined $io ? "DEF\n" : "undef\n";
                close $out;
                $w->write('chunk2');
                $w->close;
            };
        }
        if ($p eq '/retake') {
            return sub {
                require Scalar::Util;
                my %copy = %$env;               # fetches: fires the magic once
                my $io1 = $env->{'psgix.io'};
                my $io2 = $copy{'psgix.io'};
                open my $out, '>', "$dir/retake" or die $!;
                print {$out} (defined $io1 ? "DEF" : "undef"), ' ',
                                 (defined $io2 ? "DEF" : "undef"), ' ',
                                 (defined $io1 && defined $io2
                                    && Scalar::Util::refaddr($io1)
                                        == Scalar::Util::refaddr($io2)
                                  ? "same" : "alias"), "\n";
                close $out;
                if ($io1) {
                    syswrite $io1, "HTTP/1.1 200 OK\r\nContent-Length: 7\r\n"
                                 . "Connection: close\r\n\r\nretaken";
                    close $io1;
                }
            };
        }
        return [404, ['Content-Length' => 0], []];
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

sub get_body {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto => 'tcp', Timeout => 5 * TMULT) or die "connect: $!";
    $s->autoflush(1);
    print {$s} "GET $path HTTP/1.1\015\012Host: x\015\012Connection: close\015\012\015\012";
    my $r = '';
    $r .= $_ while sysread($s, $_, 65536);
    close $s;
    return $r;
}

sub read_file {
    my ($name) = @_;
    for (1 .. 100 * TMULT) {
        if (open my $fh, '<', "$dir/$name") {
            my $c = do { local $/; <$fh> };
            close $fh;
            return $c;
        }
        select undef, undef, undef, 0.05;
    }
    return undef;
}

my $stream = get_body('/stream');
is read_file('stream'), "undef\n", 'mid-response psgix.io read declines';
like $stream, qr/chunk1chunk2/, 'streamed response intact, not hijacked';

my $retake = get_body('/retake');
is read_file('retake'), "DEF DEF same\n",
    'env copy shares the single takeover, no second handle';
like $retake, qr/^HTTP\/1\.1 200 .*retaken$/s, 'manual response via taken handle works';

my $log = do {
    open my $fh, '<', "$dir/server.log" or die $!;
    local $/; <$fh>;
};
unlike $log, qr/socket already taken/, 'no spurious second-take warning';
unlike $log, qr/^EV: error/m, 'no event-loop errors';
