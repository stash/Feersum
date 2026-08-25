#!perl
# A client that disconnects mid-stream with a request pipelined behind the
# stream: the failed write must close the connection, not dispatch the
# pipelined request to a peer already known gone.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET ();
use IO::Select ();
use Socket qw(SOL_SOCKET SO_LINGER);
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep time);
use lib 't'; use Utils;
use Feersum;
use EV;

plan tests => 4;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir    = tempdir(CLEANUP => 1);
my $marker = "$dir/marker";

my ($sock, $port) = get_listen_socket();
my $pid = fork // die "fork: $!";
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($sock);
    $f->set_keepalive(1);
    my %keep;
    my $mark = sub {
        open my $m, '>>', $marker or return;
        print {$m} "@_\n";
        close $m;
    };
    $f->psgi_request_handler(sub {
        my $env = shift;
        return [200, ['Content-Type' => 'text/plain'], [$mark->("dispatch $env->{PATH_INFO}") && 'ok']]
            unless $env->{PATH_INFO} eq '/stream';
        return sub {
            my $w = $_[0]->([200, ['Content-Type' => 'text/plain']]);
            my $n = 0;
            $keep{s} = EV::timer(0.02, 0.02, sub {
                my $ok = eval { $w->write('x' x 16384); 1 };
                if (!$ok || ++$n >= 200) {
                    $mark->($ok ? 'stream done' : 'stream write failed');
                    eval { $w->close };
                    delete $keep{s};
                }
            });
        };
    });
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

sub markers { open my $m, '<', $marker or return q{}; local $/; return <$m> }

sub session {
    my ($stay) = @_;
    unlink $marker;
    my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
        Timeout => 5 * TIMEOUT_MULT) or die "connect: $!";
    syswrite $c, "GET /stream HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\n\r\n";
    my $sel = IO::Select->new($c);
    my $until = time + ($stay ? 30 : 0.3) * TIMEOUT_MULT;
    while (time < $until) {
        next unless $sel->can_read(0.05);
        my $n = sysread $c, my $buf, 65536;
        last unless $n;
        last if $stay && markers() =~ /^dispatch \/second$/m;
    }
    setsockopt $c, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0) unless $stay;
    close $c;
    my $deadline = time + 10 * TIMEOUT_MULT;
    sleep 0.05 until markers() =~ /^stream (?:write failed|done)$/m || time > $deadline;
    sleep 0.3;    # let any wrongly dispatched request reach the handler
    return markers();
}

my $m = session(1);
like $m, qr{^dispatch /second$}m,
    'control: a client that stays gets its pipelined request served';

$m = session(0);
like $m, qr/^stream write failed$/m,
    'the streaming write failed once the client was gone';
unlike $m, qr{^dispatch /second$}m,
    'the pipelined request was not dispatched to the gone peer'
    or diag "markers:\n$m";

my $exited = waitpid($pid, POSIX::WNOHANG()) == $pid;
ok !$exited, 'server still running';
kill 'QUIT', $pid unless $exited;
waitpid $pid, 0 unless $exited;
