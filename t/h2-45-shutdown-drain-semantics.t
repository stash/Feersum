#!perl
# Once shutdown begins the server sends GOAWAY and new H2 streams never reach
# the app, while in-flight streams keep their responses.
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
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    my @held;
    $f->psgi_request_handler(sub {
        my $env = shift;
        open my $fh, '>>', "$dir/dispatched" or die $!;
        print {$fh} "$env->{PATH_INFO}\n";
        close $fh;
        if ($env->{PATH_INFO} eq '/hold') {
            return sub {
                my $respond = shift;
                push @held, $respond->([200, ['Content-Type' => 'text/plain']]);
            };
        }
        return [200, ['Content-Type' => 'text/plain'], ["path=$env->{PATH_INFO}"]];
    });
    my $usr1 = EV::signal('USR1', sub { $f->graceful_shutdown(sub {}) });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

my ($s) = h2_connect($port, timeout => 5 * TMULT);
die 'H2 connect failed' unless $s;
my @base = ([':method', 'GET'], [':scheme', 'https'], [':authority', 'x']);

sub send_headers {
    my ($sid, @pairs) = @_;
    my $frame = h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
        $sid, hpack_encode_headers(@pairs));
    my $off = 0;
    while ($off < length $frame) {
        my $n = syswrite($s, $frame, length($frame) - $off, $off);
        die "write: $!" unless $n;
        $off += $n;
    }
}

send_headers(1, @base, [':path', '/hold']);
my ($kind, $status);
{
    my $deadline = time + 5 * TMULT;
    while (time < $deadline) {
        my $frame = h2_read_frame($s, $deadline - time) or last;
        next unless $frame->{stream_id} == 1 && $frame->{type} == H2_HEADERS;
        ($kind, $status) = ('HEADERS', hpack_decode_status($frame->{payload}));
        last;
    }
}
is $kind, 'HEADERS', 'the in-flight stream is dispatched';
is $status, 200, 'the in-flight stream gets its response head';

kill 'USR1', $pid;
select undef, undef, undef, 0.7 * TMULT;
send_headers(3, @base, [':path', '/late']);

my ($saw_goaway, $late_outcome) = (0, 'silence');
{
    my $deadline = time + 3 * TMULT;
    while (time < $deadline) {
        my $frame = h2_read_frame($s, $deadline - time) or last;
        $saw_goaway = 1 if $frame->{type} == H2_GOAWAY;
        next unless $frame->{stream_id} == 3;
        if ($frame->{type} == H2_HEADERS) { $late_outcome = 'dispatched'; last }
        if ($frame->{type} == H2_RST_STREAM) { $late_outcome = 'reset'; last }
    }
}
ok $saw_goaway, 'shutdown sends GOAWAY';
is $late_outcome, 'silence', 'a stream opened after shutdown gets no reply';
close $s;

my %seen;
if (open my $fh, '<', "$dir/dispatched") {
    chomp(my @paths = <$fh>);
    $seen{$_} = 1 for @paths;
}
ok $seen{'/hold'}, 'the in-flight request was dispatched';
ok !$seen{'/late'}, 'the post-shutdown stream never reaches the app';

undef $cleanup;
done_testing;
