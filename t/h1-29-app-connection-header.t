#!perl
# An app's "Connection: close" actually closes the connection instead of
# parking it in keepalive-idle, and the server never emits its own Connection
# header beside the app's.  Upgrade still passes through untouched (101 path).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use Time::HiRes ();
use POSIX ();
use Feersum;

plan tests => 9;

my $RD = 10 * TIMEOUT_MULT;    # read_timeout: the old close-latency
my @kids;

sub spawn_server {
    my ($keepalive) = @_;
    my ($lsock, $lport) = get_listen_socket();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        no warnings 'once';
        $Feersum::DIED = sub { };
        my $f = Feersum->new_instance();
        $f->use_socket($lsock);
        $f->set_keepalive($keepalive);
        $f->read_timeout($RD);
        $f->header_timeout($RD);
        $f->psgi_request_handler(sub {
            my $env = shift;
            my $p = $env->{PATH_INFO} // q{};
            return [101, ['Upgrade' => 'websocket', 'Connection' => 'Upgrade'], []]
                if $p eq '/upgrade';
            return [200, ['Content-Type' => 'text/plain',
                          'Connection' => 'keep-alive',
                          'Content-Length' => 2], ['ok']]
                if $p eq '/ka';
            return [200, ['Content-Type' => 'text/plain',
                          'Connection' => 'close',
                          'Content-Length' => 3], ['bye']];
        });
        my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $lsock;
    push @kids, $pid;
    return ($pid, $lport);
}

# Send $req, read to EOF, and report how long the server took to close.
sub ask {
    my ($port, $req) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 10 * TIMEOUT_MULT) or return ();
    my $t0 = Time::HiRes::time();
    syswrite $s, $req;
    my ($raw, $eof) = ('', 0);
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm $RD * 2;
        while (1) {
            my $n = sysread $s, my $z, 65536;
            if (!defined $n || $n == 0) { $eof = Time::HiRes::time() - $t0; last }
            $raw .= $z;
        }
        alarm 0;
        1;
    };
    alarm 0;
    close $s;
    my @conn = $raw =~ /^Connection:[ \t]*(.*?)\r$/gmi;
    my ($status) = $raw =~ m{\AHTTP/1\.\d (\d{3})};
    return ($eof, \@conn, $status // '(none)');
}

my ($srv_ka, $port_ka) = spawn_server(1);
ok $srv_ka, 'server with keepalive on';
my ($srv_no, $port_no) = spawn_server(0);
ok $srv_no, 'server with keepalive off';
select undef, undef, undef, 1 * TIMEOUT_MULT;

# --- keepalive on, HTTP/1.1, app asks to close
{
    my ($eof, $conn, $status) = ask($port_ka, "GET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    cmp_ok $eof, '<', $RD / 2,
        sprintf('an app asking to close actually closes, rather than parking '
              . 'the connection until read_timeout=%ds (closed after %.2fs)',
                $RD, $eof);
    is scalar(@$conn), 1,
        'exactly one Connection header, not the app copy plus the server one'
        or diag "got: @$conn";
    like lc($conn->[0] // q{}), qr/close/, 'and it says close';
}

# --- keepalive on, HTTP/1.0 client asking for keep-alive, app asks to close
{
    my ($eof, $conn) = ask($port_ka,
        "GET /b HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    my $joined = lc join ',', @$conn;
    ok !($joined =~ /close/ && $joined =~ /keep-alive/),
        'the response never says both close and keep-alive'
        or diag "got: @$conn";
}

# --- keepalive off (the default), app asks to close
{
    my (undef, $conn) = ask($port_no, "GET /c HTTP/1.1\r\nHost: x\r\n\r\n");
    is scalar(@$conn), 1,
        'no duplicate Connection header with keepalive off (the shipped '
      . 'examples do exactly this)'
        or diag "got: @$conn";
}

# --- Upgrade must survive untouched
{
    my (undef, $conn, $status) = ask($port_ka,
        "GET /upgrade HTTP/1.1\r\nHost: x\r\n\r\n");
    is "$status:" . lc(join ',', @$conn), '101:upgrade',
        'Connection: Upgrade still passes through on a 101';
}

# --- an app-supplied keep-alive is not duplicated either
{
    my (undef, $conn) = ask($port_ka, "GET /ka HTTP/1.1\r\nHost: x\r\n\r\n");
    cmp_ok scalar(@$conn), '<=', 1,
        'an app-supplied keep-alive does not duplicate the server header'
        or diag "got: @$conn";
}

reap_server($_) for @kids;
