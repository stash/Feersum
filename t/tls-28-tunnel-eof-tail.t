#!perl
# When the app closes its end of a TLS psgix.io takeover, the ciphertext still
# queued in tls_wbuf is drained to the client before the connection shuts down,
# so a paused client that resumes reads the whole stream.
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

plan tests => 8;

# Must exceed FEER_TUNNEL_MAX_WBUF (16 MB) so the pause actually fills the
# window and leaves a large residue queued at close time.
my $MB   = 20;
my $WANT = $MB * 1024 * 1024;
my $dir  = tempdir(CLEANUP => 1);
my $nsrv = 0;

# Deferring the close means a peer that never reads again would hold the
# connection - and its queued ciphertext - open, so the deadline has to come
# back into force once the app has let go of the socket.  Each server gets its
# own write_timeout so the drain cases are not racing it.
sub spawn_server {
    my ($write_timeout, $want) = @_;
    $want //= $WANT;
    my ($lsock, $lport) = get_listen_socket();
    my $tag = 'srv' . ++$nsrv;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', "$dir/$tag.out";
        open STDERR, '>', "$dir/$tag.log";
        no warnings 'once';
        $Feersum::DIED = sub { };
        my $f = Feersum->new_instance();
        $f->use_socket($lsock);
        $f->read_timeout(120 * TIMEOUT_MULT);
        $f->header_timeout(120 * TIMEOUT_MULT);
        $f->write_timeout($write_timeout);
        eval { $f->set_tls(listener => 0, cert_file => $cert,
                           key_file => $key, h2 => 0) };
        my %keep;
        $f->psgi_request_handler(sub {
            my $env = shift;
            return sub {
                my $io = $env->{'psgix.io'} or return; # reading the VALUE takes it
                my $id = 0 + $io;
                # Count BYTES: a partial syswrite still sent what it wrote.
                my $sent = 0;
                my $chunk = 'Z' x (256 * 1024);
                my $t;
                $t = EV::timer 0, 0.001, sub {
                    if ($sent >= $want) {
                        undef $t;
                        close $io;          # the close under test
                        delete $keep{$id};
                        return;
                    }
                    my $n = $want - $sent;
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
    close $lsock;
    return ($pid, $lport);
}

my ($server, $port) = spawn_server(120 * TIMEOUT_MULT);
ok $server, 'server started';
select undef, undef, undef, 1 * TIMEOUT_MULT;

for my $run (1 .. 2) {
    my $s = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
        SSL_verify_mode => 0, Timeout => 10 * TIMEOUT_MULT);
    ok $s, "run $run: connected";
    my $got = 0;
    if ($s) {
        print {$s} "GET /tail HTTP/1.1\r\nHost: x\r\n\r\n";
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 120 * TIMEOUT_MULT;
            # Read a couple of MB, then stall long enough for the app to fill
            # the backpressure window and reach its close.
            while ($got < 2 * 1024 * 1024) {
                my $n = sysread $s, my $z, 65536;
                last if !$n;
                $got += $n;
            }
            select undef, undef, undef, 4 * TIMEOUT_MULT;
            while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $got += $n }
            alarm 0;
            1;
        };
        alarm 0;
        close $s;
    }
    cmp_ok $got, '>=', $WANT,
        sprintf('run %d: the queued tail survives the app closing its end '
              . '(received %d of %d)', $run, $got, $WANT);
}

reap_server($server);

# --- the deferral must not become a way to pin a connection open
{
    my $deadline = 4 * TIMEOUT_MULT;
    # Keep this payload UNDER the 16 MB window: the app must be able to write
    # all of it and reach its close without being paused, so that what the
    # deadline has to reap is a connection whose app end is already gone.
    my $small = 8 * 1024 * 1024;
    my ($srv2, $port2) = spawn_server($deadline, $small);
    ok $srv2, 'second server started (write_timeout enabled)';
    select undef, undef, undef, 1 * TIMEOUT_MULT;

    my $s = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port2",
        SSL_verify_mode => 0, Timeout => 10 * TIMEOUT_MULT);
    ok $s, 'stalling client connected';
    my $got = 0;
    if ($s) {
        print {$s} "GET /stall HTTP/1.1\r\nHost: x\r\n\r\n";
        # Read just enough to get the tunnel going, then stop reading entirely.
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 10 * TIMEOUT_MULT;
            my $n = sysread $s, my $z, 4096;
            $got += $n if $n;
            alarm 0;
            1;
        };
        alarm 0;
        # Stay silent well past the deadline, then read again: a fired deadline
        # yields the socket buffer's worth and EOF, far short of $small; an
        # unreaped server hands over the whole residue.  Five intervals, not
        # three: the deadline reaps only after three drain-free checks, and
        # reading resets it.
        select undef, undef, undef, $deadline * 5;
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 60 * TIMEOUT_MULT;
            while (1) { my $n = sysread $s, my $z, 65536; last if !$n; $got += $n }
            alarm 0;
            1;
        };
        alarm 0;
        close $s;
    }
    cmp_ok $got, '<', $small,
        sprintf('a peer that stops reading after the app closes is still reaped '
              . 'by write_timeout, so the deferred close cannot pin the '
              . 'connection (got %d of %d before being cut off)', $got, $small);
    reap_server($srv2);
}
