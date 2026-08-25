#!perl
# A psgi.input poll_cb that dies while the PSGI handler is on the stack costs
# one request (a 500), never the worker: nothing above that path catches a
# croak.  Also pins that the documented poll_cb idiom releases its connection.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

plan tests => 10;

# --- max_requests_per_worker clamps like its neighbours ------------------
{
    my $f = Feersum->new_instance;
    my $nan = (9**9**9) - (9**9**9);
    is eval { $f->max_requests_per_worker($nan, sub {}); 1 } ? $f->max_requests_per_worker : 'CROAK',
       'CROAK', 'max_requests_per_worker(NaN) is refused, not silently 0';
    my $big = eval { $f->max_requests_per_worker(2**63, sub {}) } // 0;
    ok $big > 0,
       'max_requests_per_worker(2**63) is a large limit, not a croak';
}

# --- a dying psgi.input poll_cb ------------------------------------------
my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout(30 * TIMEOUT_MULT);
    my %KEEP;
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $p = $env->{PATH_INFO} // '';
        if ($p eq '/readerdie') {
            $env->{'psgi.input'}->poll_cb(sub { die "reader poll exploded\n" });
            return [200, ['Content-Type' => 'text/plain'], ['ok']];
        }
        if ($p eq '/conns') {
            return [200, ['Content-Type' => 'text/plain'], ["conns=" . $f->active_conns]];
        }
        if ($p eq '/stream') {
            return sub {
                my $w = $_[0]->([200, ['Content-Type' => 'text/plain']]);
                my $n = 0;
                $KEEP{0+$w} = $w;          # the documented idiom, corrected
                $w->poll_cb(sub {
                    $_[0]->write("chunk");
                    if ($n++ >= 2) { delete $KEEP{0+$w}; $_[0]->close }
                });
            };
        }
        return [200, ['Content-Type' => 'text/plain'], ['plain']];
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

sub ask {
    my ($path, $body) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 10 * TIMEOUT_MULT) or return '';
    my $req = defined $body
        ? "POST $path HTTP/1.1\r\nHost: x\r\nContent-Length: " . length($body)
          . "\r\nConnection: close\r\n\r\n$body"
        : "GET $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    syswrite $s, $req;
    my $raw = '';
    eval { local $SIG{ALRM} = sub { die "to\n" }; alarm 10 * TIMEOUT_MULT;
           while (sysread($s, my $c, 4096)) { $raw .= $c } alarm 0; 1 };
    alarm 0; close $s;
    return $raw;
}

# Three in a row: the first must not take the server with it.
for my $i (1 .. 3) {
    my $raw = ask('/readerdie', 'abc');
    like $raw, qr{^HTTP/1\.1 500 },
        "request $i: a dying reader poll_cb answers 500 and the server lives"
        or diag(length($raw) ? "got: " . substr($raw, 0, 60)
                             : "got NOTHING - server died");
}

like ask('/plain'), qr{^HTTP/1\.1 200 .*plain$}s,
    'the server still serves ordinary requests afterwards';

# --- the documented streaming idiom releases its connection --------------
for my $i (1 .. 3) { ask('/stream') }
select undef, undef, undef, 1 * TIMEOUT_MULT;
my $conns = ask('/conns');
my ($n) = $conns =~ /conns=(\d+)/;
ok defined $n, 'read active_conns back from the server';
cmp_ok $n, '<=', 1,
    "streamed connections are released, not stashed forever (active_conns=$n)";

like ask('/plain'), qr{200}, 'still serving after the streaming requests';

reap_server($server);
