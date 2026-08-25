#!perl
# respond_with_server_error() runs inside an ev watcher callback, where nothing
# calls FREETMPS, so its response SV must not be mortalised there.
# Author-only: measures RSS, too load-sensitive for t/.
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();

plan skip_all => 'author test' unless $ENV{FEERSUM_AUTHOR_TESTS} || $ENV{AUTHOR_TESTING};

my $rss_probe = do {
    if (open my $fh, '<', "/proc/$$/status") { close $fh; 'proc' }
    elsif (defined eval { qx{ps -o rss= -p $$ 2>/dev/null} }) { 'ps' }
    else { undef }
};
plan skip_all => 'no way to read RSS on this platform' unless $rss_probe;
plan tests => 5;

sub rss_kb {
    my $pid = shift;
    if ($rss_probe eq 'proc') {
        open my $fh, '<', "/proc/$pid/status" or return undef;
        while (<$fh>) { return $1 if /^VmRSS:\s+(\d+)/ }
        return undef;
    }
    my $out = qx{ps -o rss= -p $pid 2>/dev/null};
    return $out =~ /(\d+)/ ? $1 : undef;
}

my $sock = get_listen_socket();
my $port = $sock->sockport;

my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    # Child: the server.  Limits are set low so each error status is reachable.
    require Feersum;
    my $evh = Feersum->new;
    $evh->use_socket($sock);
    $evh->max_uri_len(64);
    $evh->max_body_len(1024);
    $evh->read_timeout(1);
    $evh->header_timeout(1);
    $evh->request_handler(sub {
        $_[0]->send_response('200 OK', ['Content-Type' => 'text/plain'], ['OK']);
    });
    my $life_timer = EV::timer(120, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

my %REQ = (
    400 => "\x01\x02 junk\r\n\r\n",
    431 => "GET / HTTP/1.1\r\nHost: x\r\n"
         . join(q{}, map {"X-Pad-$_: vvvvvvvvvvvvvvvvvvvv\r\n"} 1 .. 70) . "\r\n",
    414 => 'GET /' . ('z' x 300) . " HTTP/1.1\r\nHost: x\r\n\r\n",
    413 => "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999\r\n\r\n" . ('A' x 4096),
);

# Returns the set of statuses actually observed, so a mis-specified request
# cannot masquerade as a passing (flat) measurement.
sub hammer {
    my ($n) = @_;
    my %seen;
    for my $i (1 .. $n) {
        for my $want (sort keys %REQ) {
            my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                          Proto => 'tcp', Timeout => 5) or next;
            syswrite $s, $REQ{$want};
            my ($buf, $got) = (q{});
            while (defined($got = sysread $s, my $b, 65536)) {
                last if $got == 0;
                $buf .= $b;
                last if $buf =~ /\r\n\r\n/;
            }
            $seen{$1}++ if $buf =~ m{^HTTP/1\.\d\ (\d{3})}x;
            close $s;
        }
    }
    return \%seen;
}

sleep 1;
ok defined(rss_kb($pid)), 'can read server RSS';

hammer(60);                       # warm free lists and the allocator arena
my $base = rss_kb($pid);
my $seen = hammer(600);
my $after = rss_kb($pid);

my $responses = 0;
$responses += $seen->{$_} for keys %$seen;

is_deeply [sort keys %$seen], [qw(400 413 414 431)],
    'all four error statuses actually exercised'
    or diag explain $seen;
cmp_ok $responses, '>=', 2000, "generated $responses error responses";

my $growth = ($after - $base) * 1024;
my $per = $responses ? $growth / $responses : 0;
# The bug was a full response SV per error (~256 B).  Anything under 32 B/resp
# is allocator noise; the fixed build measures ~0 and often negative.
cmp_ok $per, '<', 32,
    sprintf('error path does not leak (%.1f B/response, RSS %d -> %d kB)',
            $per, $base, $after);

my $live = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                 Proto => 'tcp', Timeout => 5);
my $ok = 0;
if ($live) {
    syswrite $live, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    my $buf = q{};
    while (defined(my $g = sysread $live, my $b, 65536)) { last if $g == 0; $buf .= $b }
    $ok = $buf =~ m{^HTTP/1\.1\ 200}x;
    close $live;
}
ok $ok, 'server still serving normal requests afterwards';

reap_server($pid);
