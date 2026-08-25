#!perl
# A psgix.io tunnel peer that half-closes its send side (a bare FIN, which
# stop_SSL's close_notify does not produce) still receives the app's response
# over TLS, as it does on plain H1 and on H2.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    plan skip_all => "TLS not compiled in" unless Feersum->endjinn->has_tls();
    eval { require IO::Socket::SSL; require Net::SSLeay; 1 }
        or plan skip_all => "IO::Socket::SSL/Net::SSLeay not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';
    plan tests => 3;
}

use IO::Socket::INET;
use IO::Select;
use POSIX ();
use Socket qw(SOMAXCONN SHUT_WR);
use AnyEvent;
use File::Temp qw(tempdir);

my $dir = tempdir(CLEANUP => 1);
my $log = "$dir/app.log";

my ($lsn, $sport) = get_listen_socket();
my $spid = fork();
die "fork: $!" unless defined $spid;
if ($spid == 0) {
    # Under `make test` on alpine the shell that spawns the harness leaves
    # SIGQUIT ignored, and a bare Feersum child inherits that - so the
    # QUIT this test sends is a no-op and its waitpid never returns.
    $SIG{QUIT} = q{DEFAULT};
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    my $f = Feersum->new_instance();
    $f->use_socket($lsn);
    $f->set_tls(cert_file => 'eg/ssl-proxy/server.crt',
                key_file  => 'eg/ssl-proxy/server.key');
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $io = $env->{'psgix.io'} or return [500, [], ['no io']];
        syswrite $io, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nHELLO\n";
        # A watcher, not a polling loop: a loop here blocks the event loop, so
        # the server never processes the peer's FIN and no EOF ever arrives.
        our %KEEP;
        my $k = fileno($io);
        $KEEP{$k} = AE::io($io, 0, sub {
            my $n = sysread($io, my $b, 4096);
            return if !defined $n || $n > 0;
            my $ok = 0;
            for my $i (1 .. 3) { $ok++ if defined syswrite($io, "MARK$i\n") }
            if (open my $fh, '>', $log) { print $fh "eof=1 wrote=$ok\n"; close $fh }
            delete $KEEP{$k};
            close $io;
        });
        $KEEP{"t$k"} = AE::timer(10 * TIMEOUT_MULT, 0, sub {
            if (open my $fh, '>', $log) { print $fh "eof=0 wrote=0\n"; close $fh }
            delete @KEEP{$k, "t$k"};
        });
        return;
    });
    EV::run();
    POSIX::_exit(0);
}
close $lsn;

# Relay: forward both ways, but half-close toward the server once the client's
# request record has gone through (its first application record is the
# encrypted Finished, so the request is the second).
# Not get_listen_socket(): that returns a NON-blocking listener for Feersum's
# benefit, and accept() on one returns undef immediately here.
my $plsn = IO::Socket::INET->new(LocalAddr => '127.0.0.1', ReuseAddr => 1,
    Proto => 'tcp', Listen => 5) or die "proxy listen: $!";
my $pport = $plsn->sockport;
my $ppid = fork();
die "fork: $!" unless defined $ppid;
if ($ppid == 0) {
    # Under `make test` on alpine the shell that spawns the harness leaves
    # SIGQUIT ignored, and a bare Feersum child inherits that - so the
    # QUIT this test sends is a no-op and its waitpid never returns.
    $SIG{QUIT} = q{DEFAULT};
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    my $cli = $plsn->accept or POSIX::_exit(1);
    my $srv = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $sport)
        or POSIX::_exit(1);
    my ($buf, $seen, $fin) = ('', 0, 0);
    my $sel = IO::Select->new($cli, $srv);
    OUTER: while (my @r = $sel->can_read(15 * TIMEOUT_MULT)) {
        for my $fh (@r) {
            my $n = sysread($fh, my $chunk, 65536);
            if (!defined $n || $n == 0) { last OUTER if $fh == $srv; next }
            if ($fh == $srv) { syswrite($cli, $chunk); next }
            $buf .= $chunk;
            my $out = '';
            while (length($buf) >= 5) {
                my ($t, undef, $len) = unpack("C n n", $buf);
                last if length($buf) < 5 + $len;
                my $rec = substr($buf, 0, 5 + $len, '');
                $seen++ if $t == 23;
                $out .= $rec;
            }
            syswrite($srv, $out) if length $out;
            shutdown($srv, SHUT_WR) if $seen >= 2 && !$fin++;
        }
    }
    POSIX::_exit(0);
}
close $plsn;

select undef, undef, undef, 0.7 * TIMEOUT_MULT;
my $got = '';
if (my $c = IO::Socket::SSL->new(
        PeerAddr => '127.0.0.1', PeerPort => $pport,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout => 5 * TIMEOUT_MULT)) {
    syswrite $c, "GET /tunnel HTTP/1.1\r\nHost: x\r\n\r\n";
    eval { local $SIG{ALRM} = sub { die "to\n" }; alarm 15 * TIMEOUT_MULT;
           while (sysread($c, my $b, 4096)) { $got .= $b } alarm 0; 1 } or alarm 0;
    close $c;
}
else { diag "TLS connect failed: " . IO::Socket::SSL::errstr() }

my $app = '';
if (open my $fh, '<', $log) { local $/; $app = <$fh> // '' }

like $app, qr/eof=1/,   'app sees EOF when the tunnel peer half-closes';
like $app, qr/wrote=3/, 'app can still write to the tunnel after the peer EOF';
my $marks = () = $got =~ /MARK\d/g;
is $marks, 3,           'and those bytes reach the client';

kill 'QUIT', $spid, $ppid;
waitpid($_, 0) for $spid, $ppid;
