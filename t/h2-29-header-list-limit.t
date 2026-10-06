#!perl
# SETTINGS_MAX_HEADER_LIST_SIZE must bound the decoded aggregate, including
# pseudo-headers and trailers, rather than only individual HPACK strings.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    my @tunnels;
    $f->psgi_request_handler(sub {
        my $env = shift;
        return [200, [], ['accepted']] unless $env->{'psgix.h2.extended_connect'};
        return sub {
            my $writer = shift->([200, []]);
            push @tunnels, [$writer, $env->{'psgix.io'}];
        };
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
        my $offset = 0;
        while ($offset < length $frame) {
            my $n = syswrite($s, $frame, length($frame) - $offset, $offset);
            die "write: $!" unless $n;
            $offset += $n;
        }
        $first = 0;
    }
    $s->blocking(0);
}

sub response_status {
    my ($s, $sid) = @_;
    my $deadline = time + 5 * TMULT;
    while (time < $deadline) {
        my $frame = h2_read_frame($s, $deadline - time) or last;
        return hpack_decode_status($frame->{payload})
            if $frame->{type} == H2_HEADERS && $frame->{stream_id} == $sid;
        return 'reset' if $frame->{type} == H2_RST_STREAM && $frame->{stream_id} == $sid;
        return 'goaway' if $frame->{type} == H2_GOAWAY;
    }
    return 'timeout';
}

my @base = ([':method', 'GET'], [':scheme', 'https'], [':authority', 'x'], [':path', '/headers']);
my $base_size = 0;
$base_size += length($_->[0]) + length($_->[1]) + 32 for @base;

for my $extra (-1, 0, 1, 32000) {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 connect failed' unless $s;
    my $value_bytes = 65536 + $extra - $base_size - 3 * (length('x-big0') + 32);
    my $first_size = int($value_bytes / 3);
    my @pairs = (@base,
        ['x-big0', 'A' x $first_size], ['x-big1', 'B' x $first_size],
        ['x-big2', 'C' x ($value_bytes - 2 * $first_size)]);
    send_headers($s, 1, 1, @pairs);
    is response_status($s, 1), $extra > 0 ? 431 : 200,
        'decoded header list of ' . (65536 + $extra) . ' bytes obeys the limit';
    send_headers($s, 3, 1, @base);
    is response_status($s, 3), 200, 'a healthy sibling stream still works';
    close $s;
}

{
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 connect failed' unless $s;
    send_headers($s, 1, 0, [':method', 'POST'], @base[1 .. $#base]);
    send_headers($s, 1, 1, ['x-trailer0', 'A' x 32000],
        ['x-trailer1', 'B' x 32000], ['x-trailer2', 'C' x 32000]);
    is response_status($s, 1), 431, 'oversized trailers are refused before dispatch';
    send_headers($s, 3, 1, @base);
    is response_status($s, 3), 200, 'healthy stream works after rejected trailers';
    close $s;
}

{
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 connect failed' unless $s;
    # :method last, so the field that overflows the budget is the HEAD method
    send_headers($s, 1, 1, [':scheme', 'https'], [':authority', 'x' x 65363],
        [':path', '/headers'], [':method', 'HEAD']);
    my ($status, $data_bytes, $ended) = ('timeout', 0, 0);
    my $deadline = time + 5 * TMULT;
    while (time < $deadline) {
        my $frame = h2_read_frame($s, $deadline - time) or last;
        next unless $frame->{stream_id} == 1;
        $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
        $data_bytes += length($frame->{payload}) if $frame->{type} == H2_DATA;
        if ($frame->{flags} & FLAG_END_STREAM) { $ended = 1; last }
        last if $frame->{type} == H2_RST_STREAM;
    }
    is $status, 431, 'oversized HEAD headers receive 431';
    is $data_bytes, 0, 'HEAD refusal has no DATA body';
    ok $ended, 'HEAD refusal ends the response';
    close $s;
}

{
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 connect failed' unless $s;
    send_headers($s, 1, 0, [':method', 'CONNECT'], [':protocol', 'websocket'],
        [':scheme', 'https'], [':authority', 'x'], [':path', '/tunnel']);
    is response_status($s, 1), 200, 'extended CONNECT is accepted';
    send_headers($s, 1, 1, ['x-trailer0', 'A' x 32000],
        ['x-trailer1', 'B' x 32000], ['x-trailer2', 'C' x 32000]);
    is response_status($s, 1), 'reset', 'oversized trailers reset an already dispatched tunnel';
    send_headers($s, 3, 1, @base);
    is response_status($s, 3), 200, 'resetting the tunnel leaves a healthy sibling usable';
    close $s;
}

undef $cleanup;
done_testing;
