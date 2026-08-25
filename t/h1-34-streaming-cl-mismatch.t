#!perl
# A streaming body that disagrees with the app's Content-Length must not desync
# a reused connection: a surplus is cut at that length, a shortfall closes the
# connection after it.  A file that grows or shrinks between stat and read (as
# under Plack::App::File) is the everyday way to get here.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET ();
use IO::Select ();
use File::Temp qw(tempdir);
use POSIX ();
use lib 't'; use Utils;
use Feersum;
use EV;

my $linux = $^O eq 'linux';

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir = tempdir(CLEANUP => 1);
sub mkfile { my ($n, $len) = @_; open my $fh, '>', "$dir/$n" or die $!;
    print {$fh} 'F' x $len; close $fh; return "$dir/$n" }
my $f50 = mkfile('f50', 50);
my $f10 = mkfile('f10', 10);

# path => [api, declared CL, expectation, needs linux]
my %case = (
    '/fh-long'   => ['psgi',   30, 'cut'],
    '/fh-short'  => ['psgi',   30, 'close'],
    '/w-long'    => ['psgi',   10, 'cut'],
    '/w-short'   => ['psgi',   10, 'close'],
    '/w-exact'   => ['psgi',   10, 'reuse'],
    '/nw-long'   => ['native', 10, 'cut'],
    '/nw-short'  => ['native', 10, 'close'],
    '/sf-long'   => ['native', 10, 'cut',   1],
    '/sf-short'  => ['native', 30, 'close', 1],
);
my @paths = sort keys %case;
plan tests => 2 * @paths;

sub start_server {
    my ($api) = @_;
    my ($sock, $port) = get_listen_socket();
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        $SIG{QUIT} = 'DEFAULT';
        my $f = Feersum->new_instance;
        $f->use_socket($sock);
        $f->set_keepalive(1);
        if ($api eq 'psgi') {
            $f->psgi_request_handler(sub {
                my $env = shift;
                my $p = $env->{PATH_INFO};
                return [200, [], ["second"]] if $p eq '/second';
                my $cl = $case{$p}[1];
                if ($p =~ m{^/fh-}) {
                    open my $fh, '<', ($p eq '/fh-long' ? $f50 : $f10) or die $!;
                    return [200, ['Content-Length' => $cl], $fh];
                }
                my $n = { '/w-long' => 15, '/w-short' => 5, '/w-exact' => 10 }->{$p};
                return sub {
                    my $w = $_[0]->([200, ['Content-Length' => $cl]]);
                    $w->write('W' x $n);
                    $w->close;
                };
            });
        }
        else {
            $f->request_handler(sub {
                my $r = shift;
                my $p = $r->path;
                if ($p eq '/second') {
                    $r->send_response(200, [], "second");
                    return;
                }
                my $w = $r->start_streaming(200, ['Content-Length' => $case{$p}[1]]);
                if    ($p eq '/nw-long')  { $w->write('W' x 15) }
                elsif ($p eq '/nw-short') { $w->write('W' x 5) }
                elsif ($p eq '/sf-long')  { open my $fh, '<', $f50 or die; $w->sendfile($fh) }
                elsif ($p eq '/sf-short') { open my $fh, '<', $f50 or die; $w->sendfile($fh, 0, 20) }
                $w->close;
            });
        }
        my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $sock;
    return ($pid, $port);
}

sub exchange {
    my ($port, $path) = @_;
    my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
        Timeout => 5 * TIMEOUT_MULT) or return (q{}, 0);
    syswrite $c, "GET $path HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\n\r\n";
    my ($buf, $eof, $sel) = (q{}, 0, IO::Select->new($c));
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline && $buf !~ /\r\n\r\nsecond\z/) {
        next unless $sel->can_read(0.2);
        my $n = sysread $c, my $chunk, 65536;
        if (!$n) { $eof = 1; last }
        $buf .= $chunk;
    }
    close $c;
    return ($buf, $eof);
}

my %srv;
for my $api (qw(psgi native)) { @{ $srv{$api} }{qw(pid port)} = start_server($api) }

for my $p (@paths) {
    my ($api, $cl, $want, $need_linux) = @{ $case{$p} };
    SKIP: {
        skip "$p: sendfile() is Linux-only", 2 if $need_linux && !$linux;
        my ($buf, $eof) = exchange($srv{$api}{port}, $p);
        my ($head, $rest) = split /\r\n\r\n/, $buf, 2;
        $rest //= q{};
        like $head // q{}, qr/^HTTP\/1\.1 200 .*Content-Length: $cl\b/s,
            "$p: committed Content-Length $cl";
        if ($want eq 'close') {
            ok $eof && length($rest) < $cl && $rest !~ /HTTP\//,
                "$p: short body, then the connection closed (no reuse)"
                or diag 'got ' . length($rest) . " body bytes, eof=$eof";
        }
        else {
            like $rest, qr/\A[FW]{$cl}HTTP\/1\.1 200 .*\r\n\r\nsecond\z/s,
                "$p: " . ($want eq 'cut' ? 'surplus cut at' : 'body of exactly')
                . " $cl bytes, the pipelined response intact after it"
                or diag 'got ' . length($rest) . ' bytes after the headers';
        }
    }
}

for my $api (keys %srv) { kill 'QUIT', $srv{$api}{pid}; waitpid $srv{$api}{pid}, 0 }
