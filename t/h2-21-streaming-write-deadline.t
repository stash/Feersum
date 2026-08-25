#!perl
# An H2 streaming response whose poll_cb only ever writes an empty string still
# gets a write deadline: write_timeout reaps the stream rather than letting it
# pin a worker at 100% CPU, as HTTP/1.x already does for the same app.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use File::Temp ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with HTTP/2 support' unless $probe->has_h2();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
my $curl = `curl --version 2>/dev/null`;
plan skip_all => 'curl not available' unless $curl;
plan skip_all => 'curl lacks HTTP/2'  unless $curl =~ /\bHTTP2\b/;
plan skip_all => 'needs /proc for CPU accounting' unless -r "/proc/$$/stat";

plan tests => 5;

my $WT = 3 * TIMEOUT_MULT;   # write_timeout under test

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $dir = File::Temp::tempdir(CLEANUP => 1);
my $pidfile = "$dir/srv.pid";

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
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    $f->write_timeout($WT);
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 1) };
    my %keep;
    $f->request_handler(sub {
        my $r = shift;
        my $w = $r->start_streaming(200,
            ['Content-Type' => 'application/octet-stream']);
        my $id = 0 + $w;
        # /slow is the long-poll shape the deadline must NOT reap: the stream
        # is open but the app has nothing to say yet.  lib/Feersum.pm blesses
        # it and HTTP/1.x allows it, so H2 must too.
        if (($r->env->{PATH_INFO} // q{}) =~ m{/slow}) {
            my $t;
            $t = EV::timer 3 * $WT, 0, sub {
                undef $t;
                eval { $w->write('EVENT'); $w->close; 1 };
                delete $keep{$id};
            };
            $keep{$id} = [$w, \$t];
            return;
        }
        $w->poll_cb(sub { $w->write(q{}) });   # never produces a byte
        $keep{$id} = $w;
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
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

sub cpu_ms {
    open my $h, '<', "/proc/$srvpid/stat" or return -1;
    my $l = <$h>;
    close $h;
    return -1 unless defined $l;
    my ($rest) = $l =~ /\)\s+(.*)$/ or return -1;
    my @f = split ' ', $rest;
    return int((($f[11] + $f[12]) * 1000) / POSIX::sysconf(POSIX::_SC_CLK_TCK()));
}

my $base = cpu_ms();
my $client = fork();
die "fork: $!" unless defined $client;
if (!$client) {
    exec "curl -sS -k --http2 --max-time @{[ 6 * $WT ]} -o /dev/null "
       . "'https://127.0.0.1:$port/spin' >/dev/null 2>&1";
}
# Sample well past the deadline: reaped means CPU stops climbing.
select undef, undef, undef, $WT * 3;
my $burn = cpu_ms() - $base;
kill 'KILL', $client;
waitpid $client, 0;

# Spinning costs ~1000 ms of CPU per wall-clock second; being reaped at $WT
# costs about $WT seconds' worth and then nothing.
cmp_ok $burn, '<', $WT * 1000 * 2,
    sprintf('an all-empty-write H2 stream is reaped by write_timeout '
          . '(burned %d ms over %d s, spinning would be ~%d ms)',
            $burn, $WT * 3, $WT * 3 * 1000);

# The other half of the deadline's job: it must not reap a stream that is
# simply waiting.  Arming it at start_response did exactly that, killing SSE
# and long-poll apps at write_timeout with a healthy, reading client.
my $max = 12 * $WT;
for my $leg (['h2', "--http2 -k 'https://127.0.0.1:$port/slow'"],
             ['h1', "--http1.1 -k 'https://127.0.0.1:$port/slow'"]) {
    my ($name, $args) = @$leg;
    my $out = `curl -sS --max-time $max $args 2>&1`;
    like $out, qr/EVENT/,
        "$name: a long-poll stream that writes nothing yet is not reaped";
}

reap_server($server);
