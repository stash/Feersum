#!perl
# A set_tls failure in a reuseport worker child must _exit there: unguarded,
# the croak unwinds into the inherited supervisor frames and the child becomes
# a forking supervisor clone answering plaintext on the HTTPS port.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use IO::Socket::INET;
use POSIX ();

BEGIN {
    plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
    plan skip_all => 'Linux-only (reuseport + /proc)' unless $^O eq 'linux';
    plan skip_all => 'needs a POSIX fork' unless $Config::Config{d_fork}
        || eval { require Config; $Config::Config{d_fork} };
    require Feersum;
    plan skip_all => 'TLS not compiled in' unless Feersum->endjinn->has_tls();
    require Feersum::Runner;
    plan skip_all => 'SO_REUSEPORT not available'
        unless defined &Feersum::Runner::SO_REUSEPORT
            && defined Feersum::Runner::SO_REUSEPORT();
    eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not available';
    plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();
}
plan tests => 4;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $cert_src = 'eg/ssl-proxy/server.crt';
my $key_src  = 'eg/ssl-proxy/server.key';
plan skip_all => 'test certs not found' unless -f $cert_src && -f $key_src;

my $dir  = tempdir(CLEANUP => 1);
my $cert = "$dir/server.crt";
my $key  = "$dir/server.key";                 # a COPY: never chmod the repo's
copy($cert_src, $cert) or die "copy cert: $!";
copy($key_src,  $key)  or die "copy key: $!";
my $wpf = "$dir/workers.pids";                 # each worker appends its pid

sub proc_ppid {
    my $pid = shift;
    open my $s, '<', "/proc/$pid/stat" or return undef;
    my $line = <$s>; close $s;
    return undef unless defined $line && $line =~ /\)\s+\S+\s+(\d+)/;
    return $1;                                 # ppid, past the parenthesised comm
}
sub count_descendants {
    my $root = shift;
    opendir my $d, '/proc' or return -1;
    my @pids = grep { /^\d+\z/ } readdir $d; closedir $d;
    my %kids;
    for my $p (@pids) { my $pp = proc_ppid($p); push @{$kids{$pp}}, $p if defined $pp; }
    my @q = ($root); my $n = 0;
    while (@q) { my $x = shift @q; for my $c (@{$kids{$x} || []}) { $n++; push @q, $c } }
    return $n;
}
# A plaintext GET that comes back as an HTTP response means a TLS-less clone
# answered on the HTTPS port.  A real TLS worker treats the plaintext as a
# broken handshake and drops it, so this returns 0.
sub plaintext_answers {
    my ($port, $tries) = @_;
    my $hits = 0;
    for (1 .. $tries) {
        my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                      Timeout => 2 * TIMEOUT_MULT) or next;
        my $r = '';
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 2 * TIMEOUT_MULT;
            print $s "GET / HTTP/1.0\r\nHost: x\r\n\r\n";
            local $/; $r = <$s> // '';
            alarm 0; 1;
        };
        alarm 0; close $s;
        $hits++ if $r =~ m{HTTP/1\.[01]\s+200} && $r =~ /pid=\d+/;
    }
    return $hits;
}

my ($undef_sock, $port) = get_listen_socket();
undef $undef_sock;                             # free the port for the workers

my $master = fork // die "fork: $!";
if (!$master) {
    open STDOUT, '>', "$dir/master.out";
    open STDERR, '>', "$dir/master.log";
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen    => ["127.0.0.1:$port"],
            pre_fork  => 2,
            reuseport => 1,
            tls       => { cert_file => $cert, key_file => $key },
            after_fork => sub {
                open my $p, '>>', $wpf or return; print {$p} "$$\n"; close $p;
            },
            app => sub {
                $_[0]->send_response(200, ['Content-Type' => 'text/plain'],
                                     ["pid=$$"]);
            },
            quiet => 1,
        )->run;
    };
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', -$master; kill 'KILL', $master; die "watchdog\n" };
alarm 90 * TIMEOUT_MULT;

# Wait until a TLS handshake succeeds - the pool is up.
my $tls_ok = 0;
for (1 .. 100) {
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
    my $c = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
                                 SSL_verify_mode => 0, Timeout => 3 * TIMEOUT_MULT);
    if ($c) { print $c "GET / HTTP/1.0\r\n\r\n"; my $r = do { local $/; <$c> };
        close $c; $tls_ok = 1, last if ($r // '') =~ /pid=\d+/ }
}
ok $tls_ok, 'reuseport TLS pool is serving HTTPS';

# Grab a live worker pid, make the key unreadable, then kill the worker so its
# slot respawns and re-applies TLS - which now fails.
my @workers;
for (1 .. 40) {
    if (open my $wh, '<', $wpf) { @workers = map { /(\d+)/ ? $1 : () } <$wh>; close $wh }
    last if @workers;
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
}
ok scalar(@workers), 'a worker reported its pid';

chmod 0000, $key;
kill 'KILL', $workers[0] if @workers;

# Give a fork bomb time to explode, sampling the descendant count.
my $max_desc = 0;
for (1 .. 20) {
    select undef, undef, undef, 0.2 * TIMEOUT_MULT;
    my $n = count_descendants($master);
    $max_desc = $n if $n > $max_desc;
}
cmp_ok $max_desc, '<', 8,
    "no fork bomb after the reuseport TLS croak (peak $max_desc descendants)";

is plaintext_answers($port, 8), 0,
    'no plaintext HTTP answered on the TLS port';

alarm 0;
kill 'KILL', -$master if kill 0, $master;
kill 'KILL', $master  if kill 0, $master;
waitpid $master, 0;
