#!perl
# A sendfile failed by EMFILE must leave its Content-Length allowance to a
# fallback writer; closing without a fallback must not reuse the connection.
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
plan skip_all => 'sendfile requires Linux' unless $^O eq 'linux';
plan skip_all => 'BSD::Resource required for descriptor-pressure regression'
    unless eval { require BSD::Resource; 1 };
my $probe = Feersum->new_instance;
my $tls = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/body.bin";
{
    open my $out, '>', $file or die $!;
    print {$out} 'S' x 100;
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
    open my $source, '<', $file or die $!;
    open my $errors, '>', "$dir/errors" or die $!;
    $errors->autoflush(1);
    my $f = Feersum->new_instance;
    $f->use_socket($_) for @listeners;
    $f->set_tls(listener => 1, cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key') if $tls;
    $f->set_keepalive(1);
    $f->read_timeout(30 * TMULT);
    $f->write_timeout(30 * TMULT);
    $f->request_handler(sub {
        my $r = shift;
        my $env = $r->env;
        my $path = $env->{PATH_INFO};
        if ($path eq '/second') {
            $r->send_response(200, [], 'SECOND');
            return;
        }
        my $w = $r->start_streaming(200, ['Content-Length' => 100]);
        my @held;
        # only this child has the small rlimit; release it before write/close
        while (open my $fh, '<', '/dev/null') { push @held, $fh }
        my $ok = eval { $w->sendfile($source); 1 };
        my $error = $ok ? 'unexpected success' : $@;
        close $_ for @held;
        print {$errors} "$env->{'psgi.url_scheme'} $path: $error\n";
        $w->write('F' x 100) if $path eq '/fallback';
        $w->close;
    });
    my ($soft, $hard) = BSD::Resource::getrlimit(BSD::Resource::RLIMIT_NOFILE());
    my $limit = $soft < 64 ? $soft : 64;
    BSD::Resource::setrlimit(BSD::Resource::RLIMIT_NOFILE(), $limit, $hard)
        or die "setrlimit: $!";
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $_ for @listeners;

for my $i (0 .. $#ports) {
    my $transport = $i ? 'https' : 'http';
    for my $path ('/fallback', '/close') {
        subtest "$transport $path after failed duplicate" => sub {
            my $s = $i ? IO::Socket::SSL->new(
                PeerAddr => '127.0.0.1', PeerPort => $ports[$i],
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['http/1.1'], Timeout => 5 * TMULT,
            ) : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $ports[$i],
                                     Timeout => 5 * TMULT);
            die 'connect failed' unless $s;
            $s->syswrite("GET $path HTTP/1.1\r\nHost: x\r\n\r\n"
                       . "GET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
            $s->blocking(0);
            my ($wire, $eof) = ('', 0);
            my $deadline = time + 5 * TMULT;
            while (time < $deadline) {
                my $n = $s->sysread(my $bytes, 65536);
                if (defined $n) {
                    if (!$n) { $eof = 1; last }
                    $wire .= $bytes;
                } elsif (!$!{EAGAIN} && !$!{EWOULDBLOCK}) {
                    last;
                }
                select undef, undef, undef, 0.01;
            }
            close $s;
            open my $in, '<', "$dir/errors" or die $!;
            my $errors = do { local $/; <$in> };
            close $in;
            like $errors, qr/\Q$transport $path\E: sendfile: .*dup.*failed/,
                'the test exercised a file-descriptor duplication failure';
            ok $eof, 'the reply reaches EOF before the read deadline';
            my $responses = () = $wire =~ /HTTP\/1\.1 200/g;
            if ($path eq '/fallback') {
                like $wire, qr/\r\n\r\nF{100}HTTP\/1\.1 200/,
                    'the fallback body fills the original Content-Length before the next response';
                is $responses, 2, 'the complete fallback permits the pipelined response';
            } else {
                is $responses, 1, 'the short response closes without serving the pipeline';
                unlike $wire, qr/SECOND/, 'a later response cannot fill the missing body';
            }
        };
    }
}
done_testing;
