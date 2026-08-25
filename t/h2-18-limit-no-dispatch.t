#!perl
# An H2 request rejected by an administrative limit (413 from the HEADERS
# frame) never reaches the app, even when the terminating DATA+END_STREAM
# arrives as a separate frame.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use POSIX ();
use lib 't'; use Utils;
use AnyEvent;
use H2Utils;
use Feersum;

my $probe = Feersum->new();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();
my ($cert, $key) = ('t/certs/alpha.crt', 't/certs/alpha.key');
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 5;

use File::Temp qw(tempfile);
my (undef, $logfile) = tempfile(UNLINK => 1);

my ($sock, $port) = get_listen_socket();
ok $sock, "got listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->set_tls(h2 => 1, cert_file => $cert, key_file => $key);
    $f->max_body_len(4096);
    $f->read_timeout(20 * TIMEOUT_MULT);
    # Record every dispatch: a rejected request must leave no trace here.
    $f->psgi_request_handler(sub {
        my $env = shift;
        if (open my $fh, '>>', $logfile) {
            print {$fh} ($env->{PATH_INFO} // '?') . "\n";
            close $fh;
        }
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

# One H2 POST with a declared Content-Length, sent as HEADERS then DATA+END_STREAM.
sub h2_post {
    my ($path, $len) = @_;
    my ($s) = h2_connect($port, timeout => 10 * TIMEOUT_MULT);
    return unless $s;
    my $hdrs = hpack_encode_headers(
        [':method', 'POST'], [':scheme', 'https'],
        [':authority', '127.0.0.1'], [':path', $path],
        ['content-length', "$len"]);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdrs));
    $s->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, 'Z' x $len));
    my ($status, $done) = (undef, 0);
    my $deadline = time + 15 * TIMEOUT_MULT;
    while (!$done && time < $deadline) {
        my $f = h2_read_frame($s, $deadline - time) or last;
        if ($f->{type} == H2_HEADERS && $f->{stream_id} == 1) {
            $status = hpack_decode_status($f->{payload});
            $done = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        elsif ($f->{type} == H2_DATA && $f->{stream_id} == 1) {
            $done = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        elsif ($f->{type} == H2_RST_STREAM || $f->{type} == H2_GOAWAY) { $done = 1 }
    }
    close $s;
    return $status;
}

my $ok_status  = h2_post('/in-limit', 100);
my $big_status = h2_post('/over-limit', 9000);

reap_server($server);

my @dispatched;
if (open my $fh, '<', $logfile) {
    @dispatched = map { chomp; $_ } <$fh>;
    close $fh;
}

is $ok_status, 200, 'in-limit POST is answered 200';
is $big_status, 413, 'over-limit POST is answered 413';
ok scalar(grep { $_ eq '/in-limit' } @dispatched),
    'in-limit POST reached the app';
ok !scalar(grep { $_ eq '/over-limit' } @dispatched),
    'over-limit POST did NOT reach the app'
    or diag 'dispatched: ' . join(q{, }, @dispatched);
