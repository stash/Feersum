#!perl
# Slow tunnel readers must get every queued byte before EOF, and must still
# be able to answer both a TCP half-close and a TLS close_notify.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use Socket qw(SHUT_WR);
use POSIX ();
use Time::HiRes qw(time sleep);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS unavailable' unless $probe->has_tls
    && eval { require IO::Socket::SSL; require Net::SSLeay; 1 } && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key');
    my %keep;
    $f->request_handler(sub {
        my $conn = shift;
        my $path = $conn->path;
        my $io = $conn->io;
        syswrite($io, "HTTP/1.1 200 OK\r\n\r\nready\n");
        my $state = { io => $io, bytes => 0, sha => Digest::SHA->new(256) };
        $keep{$path} = $state;
        # small flat delay so client bytes queue before the app reads
        $state->{delay} = EV::timer(0.5, 0, sub {
            delete $state->{delay};
            $state->{read} = EV::io($io, EV::READ, sub {
                my $n = sysread($io, my $data, 16384);
                return unless defined $n;
                if ($n > 0) {
                    $state->{bytes} += $n;
                    $state->{sha}->add($data);
                    return;
                }
                my $result = "$state->{bytes} " . $state->{sha}->hexdigest;
                open my $out, '>', "$dir$path" or die $!;
                print {$out} "$result\n";
                close $out;
                syswrite($io, "received:$result\n");
                delete $state->{read};
                close $io;
                delete $keep{$path};
            });
        });
    });
    my $stats = EV::timer(0.05, 0.05, sub {
        open my $out, '>', "$dir/active" or die $!;
        print {$out} $f->active_conns;
        close $out;
    });
    my $life = EV::timer(40 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

my $large_payload = join('', map { pack('N', $_) } 0 .. 131071);
for my $case ('fin-empty', 'fin', 'notify-empty', 'close-notify') {
    subtest $case => sub {
        my $payload = $case =~ /empty/ ? '' : $large_payload;
        my $s = IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(), Timeout => 5 * TMULT);
        die 'TLS connect failed' unless $s;
        my ($response, $sent) = ('', 0);
        eval {
            local $SIG{ALRM} = sub { die "exchange timeout\n" };
            alarm 10 * TMULT;
            syswrite($s, "GET /$case HTTP/1.1\r\nHost: x\r\n\r\n");
            while ($response !~ /ready\n/) {
                my $n = sysread($s, my $part, 4096);
                die 'EOF before ready' unless $n;
                $response .= $part;
            }
            while ($sent < length($payload)) {
                my $n = syswrite($s, $payload, length($payload) - $sent, $sent);
                die "write: $!" unless $n;
                $sent += $n;
            }
            if ($case =~ /^fin/) {
                CORE::shutdown($s, SHUT_WR) or die "shutdown: $!";
            } else {
                my $rv = Net::SSLeay::shutdown($s->_get_ssl_object);
                die "SSL shutdown: $rv" if $rv < 0;
            }
            while (sysread($s, my $part, 4096)) { $response .= $part }
            alarm 0;
            1;
        } or do { alarm 0; diag $@ };
        is $sent, length($payload), 'client sends the complete payload';
        my $result = '';
        if (open my $in, '<', "$dir/$case") { $result = <$in> // ''; close $in; chomp $result }
        is $result, length($payload) . ' ' . sha256_hex($payload), 'all queued input arrives in order before EOF';
        like $response, qr/received:\Q$result\E\n\z/, 'app response reaches the peer after input EOF';
        close $s;
        my ($active, $deadline) = (-1, time + 2 * TMULT);
        while (time < $deadline) {
            if (open my $in, '<', "$dir/active") { $active = <$in> // -1; close $in }
            last if $active == 0;
            sleep 0.05;
        }
        is $active, 0, 'completed tunnels release their connection references';
        done_testing;
    };
}
undef $cleanup;
done_testing;
