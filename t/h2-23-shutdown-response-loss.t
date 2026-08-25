#!perl
# The last H2 stream to close while the server is shutting down (an operator
# shutdown or max_requests_per_worker retirement) still gets its response
# flushed: frames serialized inside session_send are not thrown away.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use AnyEvent;
use H2Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 5;

# Two requests, answered on a timer so the response lands while the connection
# is retiring.  $maxreq == 0 turns retirement off, which is the control.
sub run_case {
    my ($maxreq) = @_;
    my ($sock, $port) = get_listen_socket();
    return () unless $sock;

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        no warnings 'once';
        $Feersum::DIED = sub { };
        my $f = Feersum->new_instance();
        $f->use_socket($sock);
        $f->read_timeout(30 * TIMEOUT_MULT);
        $f->header_timeout(30 * TIMEOUT_MULT);
        eval { $f->set_tls(listener => 0, cert_file => $cert,
                           key_file => $key, h2 => 1) };
        # Exactly what Feersum::Runner installs for max_requests_per_worker.
        $f->max_requests_per_worker($maxreq, sub { }) if $maxreq;
        my @held;
        $f->psgi_request_handler(sub {
            my $env = shift;
            my $p = $env->{PATH_INFO} // '?';
            return sub {
                my $respond = shift;
                push @held, EV::timer 0.3 * TIMEOUT_MULT, 0, sub {
                    my $b = "body$p";
                    $respond->([200, ['Content-Type' => 'text/plain',
                                      'Content-Length' => length $b], [$b]]);
                };
            };
        });
        my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
        EV::run();
        POSIX::_exit(0);
    }
    close $sock;
    select undef, undef, undef, 1 * TIMEOUT_MULT;

    my $s = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2'], Timeout => 10 * TIMEOUT_MULT);
    if (!$s) { reap_server($pid); return () }
    $s->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" . h2_frame(H2_SETTINGS, 0, 0, ''));
    $s->blocking(0);
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($s, 1) or last;
        if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
            $s->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
            last;
        }
    }
    for my $sid (1, 3) {
        my $h = hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
            [':authority', "127.0.0.1:$port"], [':path', "/r$sid"]);
        $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                              $sid, $h));
    }

    my %body;
    my $t0 = time;
    while (time - $t0 < 20 * TIMEOUT_MULT) {
        my $f = h2_read_frame($s, 0.3) or next;
        $body{ $f->{stream_id} } .= $f->{payload} if $f->{type} == H2_DATA;
        last if 2 == grep { length } values %body;
    }
    close $s;
    reap_server($pid);
    return \%body;
}

# --- retirement on: the case that lost a response
{
    my $body = run_case(2);
    ok $body, 'retiring server: connected and spoke H2';
  SKIP: {
        skip 'no connection', 2 unless $body;
        my $got = grep { length } values %$body;
        is $got, 2,
            'both responses reach the client when the last stream closes '
          . 'during max_requests_per_worker retirement';
        is join('|', map { $body->{$_} // '' } sort { $a <=> $b } keys %$body),
           'body/r1|body/r3',
           'and they are the right bodies on the right streams';
    }
}

# --- control: retirement off, which always worked
{
    my $body = run_case(0);
    ok $body, 'control server: connected and spoke H2';
  SKIP: {
        skip 'no connection', 1 unless $body;
        my $got = grep { length } values %$body;
        is $got, 2, 'control: both responses arrive with retirement disabled';
    }
}
