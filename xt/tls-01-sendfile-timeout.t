#!perl
# TLS sendfile() resets the write deadline as it makes progress, so
# write_timeout does not reap a large download mid-file.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use Socket ();
use IO::Socket::INET ();
use EV;
use File::Temp qw(tempfile);

plan skip_all => "sendfile is Linux-only" unless $^O eq 'linux';
my $probe = Feersum->new_instance();
plan skip_all => "Feersum not compiled with TLS support" unless $probe->has_tls();
plan skip_all => "IO::Socket::SSL required"
    unless eval { require IO::Socket::SSL; 1 };

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert && -f $key;

plan tests => 4;

# Big enough that it cannot be handed to the kernel in one pass, so the
# transfer spans many write-readiness events and outlives write_timeout.
my $SIZE = 4 * 1024 * 1024;
my ($tf, $path) = tempfile(UNLINK => 1);
binmode $tf;
print {$tf} ('A' .. 'Z')[int(rand 26)] x 4096 for 1 .. ($SIZE / 4096);
close $tf or die "close: $!";
my $real = -s $path;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
eval { $feer->set_tls(cert_file => $cert, key_file => $key) };
is $@, '', "set_tls";

# Short deadline: with the bug the transfer is cut at roughly this many seconds
# regardless of how much is left.
$feer->write_timeout(2);

$feer->psgi_request_handler(sub {
    return sub {
        my $w = shift->([200, ['Content-Type' => 'application/octet-stream',
                               'Content-Length' => $real]]);
        our %KEEP; $KEEP{"$w"} = $w;
        open my $in, '<', $path or die "open: $!";
        $w->sendfile($in);
        $w->close;
        delete $KEEP{"$w"};
    };
});

run_client("tls-sendfile-not-truncated", sub {
    # A small receive buffer plus paced reads keeps the socket full, so the
    # server spends far longer than write_timeout draining it.  SO_RCVBUF must
    # be set before connect, or the negotiated window stays and the transfer
    # crawls, turning this into a timeout rather than a truncation check.
    # A real IO::Socket, not a bare glob: start_SSL on a glob is version-dependent.
    my $s = IO::Socket::INET->new(Proto => q{tcp}) or return 10;
    setsockopt($s, Socket::SOL_SOCKET(), Socket::SO_RCVBUF(), pack('I', 8192))
        or return 14;
    $s->connect(Socket::pack_sockaddr_in($port, Socket::inet_aton(q{127.0.0.1})))
        or return 15;
    IO::Socket::SSL->start_SSL($s,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
    ) or return 16;
    syswrite($s, "GET /big HTTP/1.1\015\012Host: l\015\012"
               . "Connection: close\015\012\015\012") or return 17;

    my $buf = '';
    my $body = 0;
    my $hdr_done = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 13 * TMULT;
        while (1) {
            my $n = sysread($s, my $chunk, 4096);
            last unless defined $n && $n > 0;
            if ($hdr_done) { $body += $n }
            else {
                $buf .= $chunk;
                if ($buf =~ /\015\012\015\012/) {
                    $hdr_done = 1;
                    $body = length((split /\015\012\015\012/, $buf, 2)[1] // '');
                }
            }
            select undef, undef, undef, 0.005;  # pace the reader
        }
        alarm 0;
    };
    close $s;
    return 11 if $@;
    return 12 unless $hdr_done;
    # Pre-fix: cut off at write_timeout, a fraction of the file.
    return 13 unless $body == $real;
    return 0;
});
