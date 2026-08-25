#!perl
# A pipelined request is never left in limbo: with HTTP/1.0 keep-alive the
# buffered next request is parsed at once, and a pipelined request that arrives
# half-written gets its own header_timeout and 408, just as request 1 does.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Time::HiRes ();
use POSIX ();
use Feersum;

plan tests => 6;

my $HDR = 2 * TIMEOUT_MULT;     # header_timeout
my $RD  = 30 * TIMEOUT_MULT;    # read_timeout, deliberately far larger
my $dir = tempdir(CLEANUP => 1);

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', "$dir/srv.out";
    open STDERR, '>', "$dir/srv.log";
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->read_timeout($RD);
    $f->header_timeout($HDR);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $b = $env->{PATH_INFO} // '?';
        return [200, ['Content-Type' => 'text/plain',
                      'Content-Length' => length $b], [$b]];
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

sub connect_to {
    return IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                 Timeout => 10 * TIMEOUT_MULT);
}

# Read for up to $limit seconds without ever writing again.  Returns the bytes
# and how long until EOF (0 if the connection stayed open).
sub watch {
    my ($s, $limit) = @_;
    my $t0 = Time::HiRes::time();
    my ($raw, $eof) = ('', 0);
    $s->blocking(0);
    while (Time::HiRes::time() - $t0 < $limit) {
        my $rin = '';
        vec($rin, fileno($s), 1) = 1;
        if (select(my $r = $rin, undef, undef, 0.1) > 0) {
            my $n = sysread $s, my $z, 65536;
            next if !defined $n;
            if ($n == 0) { $eof = Time::HiRes::time() - $t0; last }
            $raw .= $z;
        }
    }
    return ($raw, $eof);
}

# --- 1: HTTP/1.0 keep-alive, both requests in one segment
{
    my $s = connect_to();
    ok $s, 'HTTP/1.0 client connected';
    my $got = '';
    if ($s) {
        syswrite $s, "GET /k1 HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
                   . "GET /k2 HTTP/1.0\r\nConnection: keep-alive\r\n\r\n";
        # Crucially: never write again.  The bug left /k2 waiting for socket
        # activity that a real client would have no reason to produce.
        ($got) = watch($s, $HDR * 2);
        close $s;
    }
    my $n = () = $got =~ m{HTTP/1\.[01] 200}g;
    is $n, 2,
        'HTTP/1.0 keep-alive answers a request pipelined into the same segment '
      . "(got $n of 2 responses without sending anything further)";
}

# --- 2: same shape over HTTP/1.1, which always worked
{
    my $s = connect_to();
    my $got = '';
    if ($s) {
        syswrite $s, "GET /a1 HTTP/1.1\r\nHost: x\r\n\r\n"
                   . "GET /a2 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        ($got) = watch($s, $HDR * 2);
        close $s;
    }
    my $n = () = $got =~ m{HTTP/1\.[01] 200}g;
    is $n, 2, 'HTTP/1.1 control: both pipelined requests answered';
}

# --- 3: pipelined request left mid-header must still meet the header deadline
{
    my $s = connect_to();
    my ($got, $eof) = ('', 0);
    if ($s) {
        syswrite $s, "GET /first HTTP/1.1\r\nHost: x\r\n\r\n"
                   . "GET /second HTTP/1.1\r\nHo";
        ($got, $eof) = watch($s, $HDR * 3);
        close $s;
    }
    ok $got =~ /\b408\b/,
        'a pipelined request stalled mid-header hits the header deadline, well '
      . "inside read_timeout=$RD (408 seen: " . ($got =~ /408/ ? 'yes' : 'no')
      . ", closed after " . sprintf('%.1fs', $eof) . ')';
}

# --- 4: the same stall on the FIRST request of a connection
{
    my $s = connect_to();
    my ($got, $eof) = ('', 0);
    if ($s) {
        syswrite $s, "GET /solo HTTP/1.1\r\nHo";
        ($got, $eof) = watch($s, $HDR * 3);
        close $s;
    }
    ok $got =~ /\b408\b/,
        'control: the same stall on request 1 hits the deadline too';
}

reap_server($server);
