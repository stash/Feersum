#!perl
# An H2 streaming response outlives the 64-iteration poll_cb budget of
# h2_try_stream_write: with the socket drained and the peer's window open, the
# pump must re-invite the poll_cb rather than stall mid-body.  H1 is the control.
# Needs curl's large window - nghttp's frequent WINDOW_UPDATEs hide the stall.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with HTTP/2 support' unless $probe->has_h2();

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;

my $curl = `curl --version 2>/dev/null`;
plan skip_all => 'curl not available'      unless $curl;
plan skip_all => 'curl lacks HTTP/2'       unless $curl =~ /\bHTTP2\b/;

plan tests => 5;

my $CHUNK = 4096;
my $N     = 300;               # well past the 64-iteration budget
my $TOTAL = $CHUNK * $N;

my ($psock, $pport) = get_listen_socket();
my ($tsock, $tport) = get_listen_socket();
ok $psock && $tsock, 'listen sockets';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($psock);
    $f->use_socket($tsock);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->header_timeout(30 * TIMEOUT_MULT);
    $f->write_timeout(30 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 1, cert_file => $cert, key_file => $key, h2 => 1) };
    my %keep;
    $f->request_handler(sub {
        my $r = shift;
        # /empty interleaves zero-length writes.  They leave the response
        # buffer untouched, which the pump used to read as "the app has run
        # dry" - indistinguishable from writing nothing, and it stalled the
        # stream for good because nothing else re-invites poll_cb.
        my $empties = ($r->env->{PATH_INFO} // q{}) =~ m{/empty};
        my $w = $r->start_streaming(200,
            ['Content-Type' => 'application/octet-stream']);
        my $sent = 0;
        my $step = 0;
        my $id = 0 + $w;
        # The closure captures $w: a poll_cb registration is not a reference.
        $w->poll_cb(sub {
            if ($sent >= $N) {
                $w->poll_cb(undef);
                delete $keep{$id};
                $w->close;
                return;
            }
            if ($empties && ++$step % 3 == 0) { $w->write(q{}); return }
            $w->write('X' x $CHUNK);
            $sent++;
        });
        $keep{$id} = $w;
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $psock;
close $tsock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

my $max = 25 * TIMEOUT_MULT;
sub got {
    my ($cmd) = @_;
    my $out = `$cmd 2>/dev/null`;
    return length $out;
}

is got("curl -sS --http1.1 --max-time $max 'http://127.0.0.1:$pport/s'"), $TOTAL,
    'control: H1 plain delivers the whole streamed body';
is got("curl -sS -k --http1.1 --max-time $max 'https://127.0.0.1:$tport/s'"), $TOTAL,
    'control: H1 over TLS delivers the whole streamed body';
is got("curl -sS -k --http2 --max-time $max 'https://127.0.0.1:$tport/s'"), $TOTAL,
    'H2 keeps pumping past the write budget instead of stalling mid-body';
is got("curl -sS -k --http2 --max-time $max 'https://127.0.0.1:$tport/empty'"), $TOTAL,
    'H2 empty writes do not read as end-of-data and stall the stream';

reap_server($server);
