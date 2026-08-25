#!perl
# The TLS tunnel bounds the app->client direction of a psgix.io takeover: when
# the client stalls, server memory stays bounded (the tunnel read watcher pauses
# at FEER_TUNNEL_MAX_WBUF), and when it reads again everything still arrives.
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
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();
plan skip_all => 'needs /proc for RSS' unless -r "/proc/$$/status";

plan tests => 5;

my $MB   = 48;
my $WANT = $MB * 1024 * 1024;
my $dir  = tempdir(CLEANUP => 1);
my $pidfile = "$dir/srv.pid";

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
    $f->read_timeout(120 * TIMEOUT_MULT);
    $f->header_timeout(120 * TIMEOUT_MULT);
    $f->write_timeout(120 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 0) };
    my %keep;
    $f->psgi_request_handler(sub {
        my $env = shift;
        # /stall must NOT close when done: closing tears the tunnel down and
        # frees its buffer, so the measurement would land after the evidence
        # was released and pass on a buggy server.
        my $close_at_end = ($env->{PATH_INFO} // q{}) !~ m{/stall};
        return sub {
            my $io = $env->{'psgix.io'} or return;   # reading the VALUE takes it
            my $id = 0 + $io;
            # Count BYTES: a partial syswrite still sent what it wrote, so
            # counting iterations would push far more than $WANT.
            my $sent = 0;
            my $chunk = 'Z' x (256 * 1024);
            my $t;
            $t = EV::timer 0, 0.001, sub {
                if ($sent >= $WANT) {
                    undef $t;
                    if ($close_at_end) {
                        close $io;                   # EOF for the reader
                        delete $keep{$id};
                    }
                    return;
                }
                my $n = $WANT - $sent;
                $n = length $chunk if $n > length $chunk;
                my $w = syswrite $io, substr($chunk, 0, $n);
                $sent += $w if defined $w;
            };
            $keep{$id} = [$io, \$t];
        };
    });
    my $life_timer = EV::timer(180 * TIMEOUT_MULT, 0, sub { EV::break() });
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
sub tls_connect {
    return IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
        SSL_verify_mode => 0, Timeout => 10 * TIMEOUT_MULT);
}

# --- a client that stalls: memory must stay bounded
my $base = rss();
{
    my $s = tls_connect();
    ok $s, 'stalling client connected';
    if ($s) {
        print {$s} "GET /stall HTTP/1.1\r\nHost: x\r\n\r\n";
        # Take a little so the tunnel is live, then read nothing more.
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 5 * TIMEOUT_MULT;
            sysread $s, my $z, 4096;
            alarm 0;
            1;
        };
        alarm 0;
        select undef, undef, undef, 6 * TIMEOUT_MULT;   # let the app push
        my $growth = rss() - $base;
      SKIP: {
            # Under valgrind, RSS includes shadow memory for everything touched
            # and says nothing about what Feersum buffered; the byte-delivery
            # half of the file still runs there.
            skip 'RSS is not meaningful under valgrind', 1
                if ($ENV{LD_PRELOAD} // q{}) =~ /valgrind|vgpreload/;
            cmp_ok $growth, '<', ($WANT / 1024) / 2,
                sprintf('a stalled client does not buffer the burst in server '
                      . 'memory (RSS grew %d kB for a %d MB burst)', $growth, $MB);
        }
        close $s;
    }
    else { fail 'no growth measurement without a connection' }
}

# --- a client that reads: everything must still arrive
{
    my $s = tls_connect();
    my $got = 0;
    if ($s) {
        print {$s} "GET /drain HTTP/1.1\r\nHost: x\r\n\r\n";
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 120 * TIMEOUT_MULT;
            while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $got += $n }
            alarm 0;
            1;
        };
        alarm 0;
        close $s;
    }
    cmp_ok $got, '>=', $WANT,
        sprintf('a reading client still gets every byte, so the pause resumes '
              . '(received %d of %d)', $got, $WANT);
}

reap_server($server);
