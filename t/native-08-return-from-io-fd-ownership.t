#!perl
# io() wraps Feersum's own descriptor; after return_from_io() the app's handle
# may be dropped at any time without closing the connection Feersum reclaimed.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More tests => 6;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();

my $CRLF = "\015\012";

my ($lsn, $port) = get_listen_socket();
ok $lsn, 'made listen socket';

my $spid = fork();
die "fork: $!" unless defined $spid;
if ($spid == 0) {
    # Under `make test` on alpine the shell that spawns the harness leaves
    # SIGQUIT ignored, and a bare Feersum child inherits that - so the
    # QUIT this test sends is a no-op and its waitpid never returns.
    $SIG{QUIT} = q{DEFAULT};
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    require Feersum;
    my $f = Feersum->new_instance();
    $f->use_socket($lsn);
    $f->set_keepalive(1);
    $f->read_timeout(20 * TIMEOUT_MULT);
    my $n = 0;
    $f->request_handler(sub {
        my $req = shift;
        my $path = $req->path // '';
        if ($path eq '/takeover') {
            my $io = $req->io;
            $req->return_from_io($io);
            $io->autoflush(1);
            print $io "HTTP/1.1 200 OK${CRLF}Content-Length: 3${CRLF}${CRLF}AOK";
            return;   # $io released right here, while the connection is live
        }
        $n++;
        $req->send_response(200, ['Content-Type' => 'text/plain'], ["PONG$n"]);
    });
    EV::run();
    POSIX::_exit(0);
}
close $lsn;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
    Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT) or die "connect: $!";
$s->autoflush(1);

sub xchg {
    my ($path, $want) = @_;
    return '[write failed]'
        unless defined syswrite($s,
            "GET $path HTTP/1.1${CRLF}Host: x${CRLF}Connection: keep-alive${CRLF}${CRLF}");
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5 * TIMEOUT_MULT;
        while (1) {
            my $k = sysread($s, my $b, 4096);
            last if !defined $k || $k == 0;
            $r .= $b;
            last if $r =~ /\Q$want\E/;
        }
        alarm 0; 1;
    } or do { alarm 0 };
    return $r;
}

like xchg('/takeover', 'AOK'), qr/AOK/, 'takeover request answered by the app';

# The handle is gone now.  Feersum said it owns this socket again, so keepalive
# must still work - and keep working, since nothing has closed anything.
like xchg('/ping', 'PONG1'), qr/PONG1/,
    'keepalive survives the handle being released at end of callback';
like xchg('/ping', 'PONG2'), qr/PONG2/, 'and the connection is still usable';

# A second takeover on the same connection, to prove the duplicate is not
# leaked into the next request cycle.
like xchg('/takeover', 'AOK'), qr/AOK/, 'second takeover on the same connection';
like xchg('/ping', 'PONG3'), qr/PONG3/, 'keepalive survives that one too';

close $s;
kill 'QUIT', $spid;
waitpid $spid, 0;
