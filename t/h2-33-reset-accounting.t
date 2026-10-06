#!perl
# A peer chooses the RST_STREAM error code. NO_ERROR must count toward the
# rapid-reset budget, while normal completions and server resets must not.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my $stats = "$dir/stats";
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    open STDERR, '>', "$dir/server.log" or die $!;
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->read_timeout(30 * TMULT);
    $f->header_timeout(30 * TMULT);
    $f->max_body_len(8);
    $f->psgi_request_handler(sub { return [200, [], ['ok']] });
    my $report = EV::timer(0, 0.02, sub {
        open my $out, '>', "$stats.tmp" or die $!;
        print {$out} $f->active_conns, "\n";
        close $out;
        rename "$stats.tmp", $stats or die $!;
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

sub send_bytes {
    my ($s, $bytes) = @_;
    $s->blocking(1);
    my $offset = 0;
    while ($offset < length $bytes) {
        my $n = $s->syswrite($bytes, length($bytes) - $offset, $offset);
        last unless $n;
        $offset += $n;
    }
    $s->blocking(0);
    return $offset == length $bytes;
}

sub ping_ok {
    my ($s) = @_;
    return 0 unless send_bytes($s, h2_frame(H2_PING, 0, 0, 'budget!!'));
    my $deadline = time + 2 * TMULT;
    while (time < $deadline) {
        my $fr = h2_read_frame($s, $deadline - time) or last;
        return 0 if $fr->{type} == H2_GOAWAY;
        return 1 if $fr->{type} == H2_PING && ($fr->{flags} & FLAG_ACK)
                    && $fr->{payload} eq 'budget!!';
    }
    return 0;
}

sub wait_released {
    my $deadline = time + 2 * TMULT;
    while (time < $deadline) {
        if (open my $in, '<', $stats) {
            my $active = <$in>;
            close $in;
            return 1 if defined $active && $active =~ /^0\s*$/;
        }
        select undef, undef, undef, 0.02;
    }
    return 0;
}

# Static :method GET, :path /, :scheme https, and literal :authority x.
my $get = "\x82\x84\x87\x01\x01x";
for my $case (['NO_ERROR', 0], ['CANCEL', 8], ['unknown error code', 0xfedcba98]) {
    subtest "peer reset with $case->[0]" => sub {
        my $s = h2_connect($port) or die 'H2 connect failed';
        my $batch = '';
        for my $n (0 .. 199) {
            my $sid = 2 * $n + 1;
            $batch .= h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid, $get)
                    . h2_frame(H2_RST_STREAM, 0, $sid, pack('N', $case->[1]));
        }
        ok send_bytes($s, $batch), 'sent 200 opened and reset streams';
        ok ping_ok($s), 'connection stays usable at the reset threshold';
        ok send_bytes($s, h2_frame(H2_HEADERS, FLAG_END_HEADERS, 401, $get)
                       . h2_frame(H2_RST_STREAM, 0, 401, pack('N', $case->[1]))),
            'sent the reset exceeding the budget';
        ok !ping_ok($s), 'exceeding the budget terminates the session';
        # checked before close: the server must release the socket on its own
        ok wait_released(), 'the closed connection releases its admission slot';
        close $s;
        ok wait_released(), 'no connection remains after client cleanup';
    };
}

for my $kind ('completed requests', 'body-limit resets', 'invalid-header resets') {
    subtest "$kind do not spend the peer reset budget" => sub {
        my $s = h2_connect($port) or die 'H2 connect failed';
        my $received = 0;
        my $healthy = 1;
        my $lib_conn_error;
        BATCH: for my $start (0, 50, 100, 150, 200) {
            my $batch = '';
            for my $n ($start .. $start + 49) {
                my $sid = 2 * $n + 1;
                if ($kind eq 'body-limit resets') {
                    my $post = "\x83\x84\x87\x01\x01x";
                    $batch .= h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid, $post)
                            . h2_frame(H2_DATA, FLAG_END_STREAM, $sid, '123456789');
                } elsif ($kind eq 'invalid-header resets') {
                    # duplicate :path, rejected by nghttp2 rather than h2_submit_rst
                    $batch .= h2_frame(H2_HEADERS, FLAG_END_HEADERS, $sid,
                                      "\x82\x84\x84\x87\x01\x01x");
                } else {
                    $batch .= h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                                      $sid, $get);
                }
            }
            unless (send_bytes($s, $batch)) { $healthy = 0; last }
            my %done;
            my $deadline = time + 3 * TMULT;
            while (keys(%done) < 50 && time < $deadline) {
                my $fr = h2_read_frame($s, $deadline - time);
                if (!$fr || $fr->{type} == H2_GOAWAY) {
                    # nghttp2 1.67-1.68 answer a malformed request with a
                    # connection error; the flood guard cannot fire on stream 1
                    my ($last, $code) = $fr ? unpack('NN', $fr->{payload}) : ();
                    $lib_conn_error = $kind eq 'invalid-header resets' && !$received
                        && defined $code && $code == 1 && $last == 1;
                    $healthy = 0;
                    last BATCH;
                }
                next unless $fr->{stream_id};
                if ($kind eq 'completed requests') {
                    if ($fr->{type} == H2_RST_STREAM) { $healthy = 0; last BATCH }
                    next unless ($fr->{type} == H2_HEADERS || $fr->{type} == H2_DATA)
                                && ($fr->{flags} & FLAG_END_STREAM);
                } else {
                    next unless $fr->{type} == H2_RST_STREAM;
                }
                $received++ unless $done{$fr->{stream_id}}++;
            }
            unless (keys(%done) == 50) { $healthy = 0; last }
        }
        SKIP: {
            skip 'this nghttp2 rejects a malformed request with a connection error', 3
                if $lib_conn_error;
            ok $healthy, 'received all completions without a flood rejection';
            is $received, 250, 'processed more streams than the peer reset budget';
            ok ping_ok($s), 'the connection remains usable';
        }
        close $s;
        ok wait_released(), 'connection cleanup releases all resources';
    };
}

done_testing;
