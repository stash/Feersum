#!perl
# A handshake message spanning many records (an enormous ClientHello sent in
# fragments) is capped at FEER_TLS_MAX_HANDSHAKE_BUF: picotls rejects it and
# the connection is dropped, rather than growing the server without bound.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;

plan tests => 5;

my $dir = tempdir(CLEANUP => 1);
my $pidfile = "$dir/srv.pid";
my $CAP = 65536;                        # FEER_TLS_MAX_HANDSHAKE_BUF
my $ANNOUNCE = 16_000_000;              # claimed ClientHello length
# Stay well under $ANNOUNCE: push that much and the message *completes*, and
# picotls rejects the garbage on its own merits - which looks like the cap
# working on a server that has no cap at all.
my $PUSH = 8 * 1024 * 1024;

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', "$dir/srv.out";
    open STDERR, '>', "$dir/srv.log";
    if (open my $pf, '>', $pidfile) { print {$pf} "$$\n"; close $pf }
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    # Generous timeouts: the point is that neither one is what stops this.
    $f->read_timeout(120 * TIMEOUT_MULT);
    $f->header_timeout(120 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 0) };
    $f->psgi_request_handler(sub {
        [200, ['Content-Type' => 'text/plain'], ['ok']];
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

my $srvpid;
for (1 .. 60) {
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
    if (open my $h, '<', $pidfile) {
        my $l = <$h>;
        close $h;
        if (defined $l) { chomp $l; $srvpid = $l; last if $srvpid }
    }
}
ok $srvpid, 'server reported its pid';

sub rss {
    open my $h, '<', "/proc/$srvpid/status" or return -1;
    my $v = -1;
    while (<$h>) { $v = $1 if /VmRSS:\s+(\d+)/ }
    close $h;
    return $v;
}
my $base = rss();

my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                              Timeout => 10 * TIMEOUT_MULT);
ok $s, 'raw client connected';

my ($sent, $closed, $peak) = (0, 0, $base);
if ($s) {
    local $SIG{PIPE} = 'IGNORE';
    # A handshake header announcing a large ClientHello, then a stream of
    # record-sized fragments that never complete it.
    my $body  = "\x01" . substr(pack('N', $ANNOUNCE), 1);   # 3-byte length
    my $first = "\x16\x03\x03" . pack('n', length $body) . $body;
    syswrite $s, $first;
    my $frag = "\x16\x03\x03" . pack('n', 16384) . ("\x00" x 16384);
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 60 * TIMEOUT_MULT;
        my $next_sample = 0;
        while ($sent < $PUSH) {
            my $n = syswrite $s, $frag;
            if (!defined $n || $n == 0) { $closed = 1; last }
            $sent += $n;
            # Sample while the connection is still up: closing frees whatever
            # was accumulated, so a reading taken afterwards would look clean
            # on a server that had been buffering all of it.
            if ($sent >= $next_sample) {
                $next_sample = $sent + 1024 * 1024;
                my $r = rss();
                $peak = $r if $r > $peak;
            }
        }
        alarm 0;
        1;
    };
    alarm 0;
}

my $growth = $peak - $base;
close $s if $s;

ok $closed,
    sprintf('the server rejects the oversized handshake message instead of '
          . 'buffering it (dropped us after %d bytes, cap is %d)', $sent, $CAP);

SKIP: {
    skip 'needs /proc for RSS', 1 unless $base > 0;
    # Anything approaching the amount pushed means it was being accumulated.
    cmp_ok $growth, '<', ($PUSH / 1024) / 4,
        sprintf('the reassembly buffer stays bounded (peak RSS grew %d kB while '
              . 'we pushed %d MB)', $growth, $PUSH / 1024 / 1024);
}

reap_server($server);
