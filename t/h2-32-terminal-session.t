#!perl
# A terminal nghttp2 session must release its socket even when the rejected
# peer keeps sending. A normal GOAWAY must still allow in-flight replies.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);
use Errno qw(EAGAIN EWOULDBLOCK);
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->read_timeout(0.4 * TMULT);
    my (%timers, $next_timer);
    $f->psgi_request_handler(sub {
        return sub {
            my $respond = shift;
            my $id = ++$next_timer;
            $timers{$id} = EV::timer(0.2 * TMULT, 0, sub {
                delete $timers{$id};
                $respond->([200, [], ['done']]);
            });
        };
    });
    my $stats = EV::timer(0.02, 0.02, sub {
        open my $out, '>', "$dir/active.tmp" or die $!;
        print {$out} $f->active_conns;
        close $out;
        rename "$dir/active.tmp", "$dir/active" or die $!;
    });
    my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

for my $bad (['invalid ping length', h2_frame(H2_PING, 0, 0, '')],
             ['data on stream zero', h2_frame(H2_DATA, 0, 0, 'x')]) {
    subtest $bad->[0] => sub {
        my ($s) = h2_connect($port, timeout => 5 * TMULT);
        die 'H2 connect failed' unless $s;
        $s->syswrite($bad->[1]);
        my $goaway = h2_read_until($s, H2_GOAWAY, 0, 2 * TMULT);
        ok $goaway, 'protocol error emits GOAWAY';
        my $closed = 0;
        my $deadline = time + 1.5 * TMULT;
        local $SIG{PIPE} = 'IGNORE';
        while (time < $deadline) {
            # keep the idle clock fresh so only the terminal-session close ends it
            $s->syswrite(h2_frame(H2_PING, 0, 0, '12345678'));
            my $n = $s->sysread(my $bytes, 65536);
            if ((defined $n && $n == 0)
                || (!defined $n && $! != EAGAIN && $! != EWOULDBLOCK)) {
                $closed = 1;
                last;
            }
            sleep 0.05 * TMULT;
        }
        ok $closed, 'terminal session closes despite continuing input';
        my $active = -1;
        $deadline = time + 1 * TMULT;
        while (time < $deadline) {
            if (open my $in, '<', "$dir/active") { $active = <$in> // -1; close $in }
            last if $active == 0;
            $s->syswrite(h2_frame(H2_PING, 0, 0, '12345678')) unless $closed;
            sleep 0.05 * TMULT;
        }
        is $active, 0, 'terminated connection releases admission capacity';
        close $s;
        done_testing;
    };
}

subtest 'client GOAWAY preserves an in-flight reply' => sub {
    my ($s) = h2_connect($port, timeout => 5 * TMULT);
    die 'H2 reconnect failed' unless $s;
    my $headers = hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
        [':authority', 'x'], [':path', '/']);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1, $headers)
        . h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    my $head = h2_read_until($s, H2_HEADERS, 1, 5 * TMULT);
    is $head ? hpack_decode_status($head->{payload}) : undef, 200, 'pending request still gets its status';
    my $data = h2_read_until($s, H2_DATA, 1, 5 * TMULT);
    is $data ? $data->{payload} : undef, 'done', 'pending response is fully delivered';
    close $s;
    done_testing;
};
undef $cleanup;
done_testing;
