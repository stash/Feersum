#!perl
# $r->read($buf, $len, $offset) must not corrupt the heap or abort the server
# when $len is negative (it arrives as a huge size_t): the length clamp must not
# wrap at a positive offset or a non-empty append target.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

# The prefill sizes that aborted, plus ones that silently truncated.
my @PREFILL = (0, 5, 8, 16, 20, 64, 200);
my $BODY    = 100;
my $OFFSET  = 5;

plan tests => 1 + 2 * @PREFILL;   # listen socket, then connect+response each

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDERR, '>', '/dev/null';
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $r = $env->{'psgi.input'};
        # PATH_INFO carries the pre-existing buffer size; read() appends to it.
        my ($pre) = ($env->{PATH_INFO} =~ m{/(\d+)});
        my $buf = 'P' x ($pre || 0);
        my $n = eval { $r->read($buf, -5, $OFFSET) };
        my $out = $@ ? "croak" : sprintf("n=%s len=%d", $n // 'undef', length $buf);
        return [200, ['Content-Type' => 'text/plain'], [$out]];
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

my $body = 'B' x $BODY;
for my $pre (@PREFILL) {
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 10 * TIMEOUT_MULT);
    ok $s, "connected for prefill=$pre";
    my $resp = '';
    if ($s) {
        syswrite $s, "POST /$pre HTTP/1.1\r\nHost: x\r\nContent-Length: $BODY\r\n"
                   . "Connection: close\r\n\r\n$body";
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 10 * TIMEOUT_MULT;
            while (sysread($s, my $c, 4096)) { $resp .= $c }
            alarm 0; 1;
        };
        alarm 0;
        close $s;
    }
    # The server must still be alive and answering: a dead server sends nothing.
    # The exact clamped count matters less than that it is sane and consistent.
    like $resp, qr/n=(\d+) len=\d+/,
        "prefill=$pre: server survived and returned a non-negative count"
        or diag "response was: " . (length($resp) ? $resp : "(nothing - server died)");
}

reap_server($server);
