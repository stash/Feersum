#!perl
use warnings;
use strict;
use constant CLIENTS => 10;
use Test::More;

BEGIN {
    if (eval q{
        require Test::LeakTrace; $Test::LeakTrace::VERSION >= 0.13
    }) {
        plan tests => 8;
    }
    else {
        plan skip_all => "Need Test::LeakTrace >= 0.13 to run this test"
    }
}

use lib 't'; use Utils;
use Test::LeakTrace;
use AnyEvent::Handle;
use IO::Socket::INET;
use POSIX ();
use EV;
BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();
{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        fail "Died during request handler: $err";
    };
}
$evh->use_socket($socket);

my $APP = <<'EOAPP';
    my $app = sub {
        return [200, ['Content-Type' => 'text/plain'], ['Hello ','World']];
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' or diag $@;
$evh->psgi_request_handler($app);


# Test::LeakTrace runs the block twice (warm-up, then counted), so the requests
# are driven by a silent client: simple_client's implicit TAP line would double,
# and a guard that skips the second run would make the count vacuous.
my @results;
sub silent_requests {
    my ($collect) = @_;
    my $cv = AE::cv;
    for my $n (1 .. CLIENTS) {
        $cv->begin;
        my $h; $h = AnyEvent::Handle->new(
            connect  => ['127.0.0.1', $port],
            on_error => sub { $cv->end; undef $h },
            on_eof   => sub { $cv->end; undef $h },
        );
        $h->push_write("GET / HTTP/1.0\015\012\015\012");
        $h->push_read(regex => qr/\015\012\015\012/, sub {
            my ($hdl, $hdr) = @_;
            $hdl->push_read(chunk => 11, sub {
                # Only when asked: anything retained here would be counted as
                # a leak by the no_leaks_ok round below.
                push @results, { head => $hdr, body => $_[1] } if $collect;
                $cv->end;
                undef $h;
            });
        });
    }
    $cv->recv;
    return;
}

# Correctness first, collecting, outside any leak-counted region.
silent_requests(1);
is scalar(@results), CLIENTS, "all clients answered";
my $bad = grep { $_->{head} !~ m{^HTTP/1\.[01] 200}
                 || $_->{head} !~ /text\/plain/
                 || $_->{body} ne 'Hello World' } @results;
is $bad, 0, "every response was a correct 200 text/plain Hello World";

# Now the leak measurement.  The clients run in a CHILD process: AnyEvent
# retains a few SVs per connection on the BSDs (48-54 for ten clients), and
# counting those made this a test of the client, red on every BSD run.  Only
# the server's own accept/parse/respond work happens in this process now.
sub served_requests_in_child {
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    unless ($pid) {
        $SIG{QUIT} = 'DEFAULT';
        my $ok = 0;
        for (1 .. CLIENTS) {
            my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                          Proto => 'tcp', Timeout => 10) or next;
            print {$s} "GET / HTTP/1.0\015\012\015\012";
            my $buf = ''; my $n;
            $buf .= $_ while defined($n = <$s>) and $_ = $n;
            $ok++ if $buf =~ /Hello World/;
            close $s;
        }
        POSIX::_exit($ok == CLIENTS ? 0 : 1);
    }
    my $done = 0;
    my $cw = EV::child($pid, 0, sub { $done = $_[0]->rstatus; EV::break() });
    my $guard = EV::timer(30, 0, sub { EV::break() });
    EV::run;
    waitpid $pid, 0;
    return $done == 0;
}

my $served;
no_leaks_ok { $served = served_requests_in_child() } 'request leaks';
ok $served, "the leak-counted round actually served its requests";

# graceful_shutdown deliberately has no leak block: it is a one-shot (a second
# call croaks "already shutting down"), and Test::LeakTrace invokes its block
# twice, so any such block can only be made to "pass" by neutering the second
# run - which is exactly the vacuous shape this file used to have.
my $cv = AE::cv;
$evh->graceful_shutdown(sub { $cv->send });
$cv->recv;
pass "graceful shutdown completed";
undef $evh;
