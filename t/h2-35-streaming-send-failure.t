#!perl
# A peer can disconnect between response headers and an asynchronous write.
# A failed send must not give an orphaned stream a new write-timer reference.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use Socket qw(SOL_SOCKET SO_LINGER);
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    open STDERR, '>', "$dir/server.log" or die $!;
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->read_timeout(30 * TMULT);
    $f->write_timeout(30 * TMULT);
    my $send;
    $f->psgi_request_handler(sub {
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            $send = EV::timer(0.3 * TMULT, 0, sub {
                # stop here so this send, not a read watcher, sees the TCP reset
                kill 'STOP', $$ or die "stop: $!";
                $w->write('delayed body');
                $w->close;
                undef $w;
                undef $send;
                $f->graceful_shutdown(sub {
                    open my $out, '>', "$dir/drained" or die $!;
                    print {$out} $f->active_conns, "\n";
                    close $out;
                });
            });
        };
    });
    my $report = EV::timer(0, 0.02, sub {
        open my $out, '>', "$dir/stats.tmp" or die $!;
        print {$out} $f->active_conns, "\n";
        close $out;
        rename "$dir/stats.tmp", "$dir/stats" or die $!;
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { kill 'CONT', $pid; reap_server($pid) };
close $listen;

my $s = h2_connect($port) or die 'H2 connect failed';
$s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
                     "\x82\x84\x87\x01\x01x"));
my $headers = h2_read_until($s, H2_HEADERS, 1, 2 * TMULT);
is $headers ? hpack_decode_status($headers->{payload}) : 'no response', 200,
    'the streaming response starts before the client disconnects';
{
    local $SIG{ALRM} = sub { die "server did not reach the delayed write\n" };
    alarm 5 * TMULT;
    waitpid($pid, POSIX::WUNTRACED()) == $pid or die "wait for stop: $!";
    alarm 0;
}
setsockopt($s, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) or die "linger: $!";
$s->close(SSL_no_shutdown => 1);
select undef, undef, undef, 0.05;
kill 'CONT', $pid or die "resume: $!";

my $deadline = time + 2 * TMULT;
select undef, undef, undef, 0.02 while !-f "$dir/drained" && time < $deadline;
open my $in, '<', "$dir/server.log" or die $!;
my $errors = do { local $/; <$in> };
close $in;
like $errors, qr/(?:TLS flush error in H2 session_send|nghttp2_session_send error)/,
    'the test exercised a streaming send failure';
ok -f "$dir/drained", 'graceful shutdown completes without waiting for write_timeout';
# the drained file holds active_conns at drain time: authoritative, no torn sample
open $in, '<', "$dir/drained" or die $!;
chomp(my $active = <$in> // 'missing');
close $in;
is $active, 0, 'the closed connection and its stream release all resources promptly';
done_testing;
