#!perl
# An application can launch a subprocess while another response is still
# sending a file. Feersum's private duplicate must not survive exec.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
plan skip_all => 'sendfile requires Linux and /proc/self/fd'
    unless $^O eq 'linux' && -d '/proc/self/fd';
my $probe = Feersum->new_instance;
my $tls = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/body.bin";
my $size = 64 * 1024 * 1024;
{
    open my $out, '>', $file or die $!;
    truncate($out, $size) or die "truncate: $!";
    close $out;
}
my @listeners = (scalar get_listen_socket());
push @listeners, scalar get_listen_socket() if $tls;
my @ports = map { $_->sockport } @listeners;
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    open STDERR, '>', "$dir/server.log" or die $!;
    my $f = Feersum->new_instance;
    $f->use_socket($_) for @listeners;
    $f->set_tls(listener => 1, cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key') if $tls;
    $f->read_timeout(30 * TMULT);
    $f->write_timeout(30 * TMULT);
    $f->request_handler(sub {
        my $r = shift;
        my $transport = $r->env->{'psgi.url_scheme'};
        open my $fh, '<', $file or die $!;
        my $w = $r->start_streaming(200, ['Content-Length' => $size]);
        $w->sendfile($fh);
        close $fh;

        opendir my $fds, '/proc/self/fd' or die $!;
        my $pending = grep { (readlink("/proc/self/fd/$_") // '') eq $file } readdir $fds;
        closedir $fds;
        my $inspect = q{
            opendir my $fds, '/proc/self/fd' or die $!;
            my $count = grep { (readlink("/proc/self/fd/$_") // '') eq $ARGV[0] } readdir $fds;
            closedir $fds;
            print "$count\n";
        };
        open my $child, '-|', $^X, '-e', $inspect, $file or die "exec probe: $!";
        my $inherited = <$child>;
        close $child or die "exec probe failed: $?";
        open my $out, '>', "$dir/$transport.tmp" or die $!;
        print {$out} "$pending\n$inherited";
        close $out;
        rename "$dir/$transport.tmp", "$dir/$transport" or die $!;
        $w->close;
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $_ for @listeners;

for my $i (0 .. $#ports) {
    my $transport = $i ? 'https' : 'http';
    subtest "pending $transport sendfile" => sub {
        my $s = $i ? IO::Socket::SSL->new(
            PeerAddr => '127.0.0.1', PeerPort => $ports[$i],
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            SSL_alpn_protocols => ['http/1.1'], Timeout => 5 * TMULT,
        ) : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $ports[$i],
                                 Timeout => 5 * TMULT);
        die 'connect failed' unless $s;
        $s->syswrite("GET /file HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        my $deadline = time + 5 * TMULT;
        select undef, undef, undef, 0.02 while !-f "$dir/$transport" && time < $deadline;
        my ($pending, $inherited);
        if (open my $in, '<', "$dir/$transport") {
            chomp($pending = <$in> // 'missing');
            chomp($inherited = <$in> // 'missing');
            close $in;
        }
        is $pending, 1, 'Feersum still owns the file after the caller closes it';
        is $inherited, 0, 'the executed child does not inherit the private file descriptor';
        close $s;
    };
}
done_testing;
