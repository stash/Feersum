#!perl
# A stream answered 431 for an oversized decoded header list must reset on
# the first DATA chunk instead of staying open for a dribble.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use constant ENHANCE_YOUR_CALM => 0xb;

my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();

my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->read_timeout(30 * TMULT);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->psgi_request_handler(sub {
        open my $fh, '>>', "$dir/dispatched" or die $!;
        print {$fh} "yes\n";
        close $fh;
        return [200, [], ['accepted']];
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

sub send_headers {
    my ($s, $sid, $end_stream, @pairs) = @_;
    my $block = hpack_encode_headers(@pairs);
    my $first = 1;
    $s->blocking(1);
    while (length $block) {
        my $part = substr($block, 0, 16000, '');
        my $flags = (length($block) ? 0 : FLAG_END_HEADERS)
                  | ($first && $end_stream ? FLAG_END_STREAM : 0);
        my $frame = h2_frame($first ? H2_HEADERS : 9, $flags, $sid, $part);
        my $off = 0;
        while ($off < length $frame) {
            my $n = syswrite($s, $frame, length($frame) - $off, $off);
            die "write: $!" unless $n;
            $off += $n;
        }
        $first = 0;
    }
    $s->blocking(0);
}

sub stream_outcome {
    my ($s, $sid, $timeout) = @_;
    my $deadline = time + $timeout;
    while (time < $deadline) {
        my $frame = h2_read_frame($s, $deadline - time) or last;
        return ('goaway', undef) if $frame->{type} == H2_GOAWAY;
        next unless $frame->{stream_id} == $sid;
        return ('HEADERS', hpack_decode_status($frame->{payload}))
            if $frame->{type} == H2_HEADERS;
        return ('RST', unpack('N', $frame->{payload}))
            if $frame->{type} == H2_RST_STREAM;
    }
    return ('timeout', undef);
}

my ($s) = h2_connect($port, timeout => 5 * TMULT);
die 'H2 connect failed' unless $s;

my @big = ([':method', 'POST'], [':scheme', 'https'], [':authority', 'x'],
    [':path', '/upload'], ['x-big0', 'A' x 22000], ['x-big1', 'B' x 22000],
    ['x-big2', 'C' x 22000]);
send_headers($s, 1, 0, @big);
my ($kind, $status) = stream_outcome($s, 1, 5 * TMULT);
is $kind, 'HEADERS', 'oversized headers get a response';
is $status, 431, 'oversized headers are refused with 431';

my $data = h2_frame(H2_DATA, 0, 1, 'x' x 4096);
is syswrite($s, $data), length($data), 'post-refusal DATA sent';
($kind, my $code) = stream_outcome($s, 1, 5 * TMULT);
is $kind, 'RST', 'DATA after the limit response resets the stream';
is $code, ENHANCE_YOUR_CALM, 'the reset carries ENHANCE_YOUR_CALM';

send_headers($s, 3, 1, [':method', 'GET'], [':scheme', 'https'],
    [':authority', 'x'], [':path', '/healthy']);
($kind, $status) = stream_outcome($s, 3, 5 * TMULT);
is $kind, 'HEADERS', 'a sibling stream still works';
is $status, 200, 'the connection stays usable';
{
    my $deadline = time + 5 * TMULT;
    while (time < $deadline) {
        my $frame = h2_read_frame($s, $deadline - time) or last;
        last if $frame->{stream_id} == 3 && ($frame->{flags} & FLAG_END_STREAM);
    }
    select undef, undef, undef, 0.2;
}
close $s;

my @dispatches;
if (open my $fh, '<', "$dir/dispatched") { chomp(@dispatches = <$fh>) }
is scalar @dispatches, 1, 'only the healthy sibling reaches the app';

undef $cleanup;
done_testing;
