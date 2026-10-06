#!perl
# An aborted download must invoke the PSGI body's close() even if getline()
# has not reached EOF.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_LINGER SO_RCVBUF);
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
my $tls = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $h2 = $tls && $probe->has_h2;
my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/download";
my $size = 64 * 1024 * 1024;
{
    open my $out, '>', $file or die $!;
    truncate($out, $size) or die "truncate: $!";
    close $out;
}
{
    package DownloadBody;
    sub new {
        my ($class, $file, $report, $env) = @_;
        open my $fh, '<', $file or die $!;
        # holds env as middleware wrappers do, so GC alone cannot clean up
        return bless { fh => $fh, report => $report, env => $env,
                       bytes => 0, closes => 0 }, $class;
    }
    sub getline {
        my $self = shift;
        my $n = read $self->{fh}, my $bytes, 8192;
        die "read: $!" unless defined $n;
        $self->{bytes} += $n;
        return $n ? $bytes : undef;
    }
    sub close {
        my $self = shift;
        CORE::close $self->{fh};
        delete $self->{env};
        $self->{closes}++;
        open my $out, '>', $self->{report} or die $!;
        print {$out} "$self->{closes} $self->{bytes}\n";
        CORE::close $out;
        return 1;
    }
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
    $f->set_tls(listener => 1, cert_file => 't/certs/alpha.crt',
                key_file => 't/certs/alpha.key', h2 => $h2 ? 1 : 0) if $tls;
    $f->read_timeout(30 * TMULT);
    $f->write_timeout(30 * TMULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $transport = substr $env->{PATH_INFO}, 1;
        return [200, ['Content-Type' => 'text/plain'], ['probe']] if $transport eq 'probe';
        return [200, ['Content-Type' => 'application/octet-stream', 'Content-Length' => $size],
                DownloadBody->new($file, "$dir/$transport.closed", $env)];
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
my $cleanup = guard { reap_server($pid) };
close $_ for @listeners;
my @transports = ('http');
push @transports, 'https' if $tls;
push @transports, 'h2', 'h2_reset' if $h2;
for my $transport (@transports) {
    subtest "$transport interrupted download" => sub {
        my $s;
        if ($transport =~ /^h2/) {
            $s = h2_connect($ports[1]) or die 'H2 connect failed';
            $s->syswrite(h2_frame(H2_SETTINGS, 0, 0, pack('nN', 4, 0))
                . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
                    hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                                         [':authority', 'x'], [':path', "/$transport"])));
            my $headers = h2_read_until($s, H2_HEADERS, 1, 3 * TMULT);
            is $headers ? hpack_decode_status($headers->{payload}) : 'no response', 200,
                'the file response has started';
            if ($transport eq 'h2_reset') {
                $s->syswrite(h2_frame(H2_RST_STREAM, 0, 1, pack('N', 8))
                    . h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3,
                        hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                                             [':authority', 'x'], [':path', '/probe'])));
                my $next = h2_read_until($s, H2_HEADERS, 3, 3 * TMULT);
                is $next ? hpack_decode_status($next->{payload}) : 'no response', 200,
                    'resetting the download leaves sibling requests usable';
                my $deadline = time + 3 * TMULT;
                select undef, undef, undef, 0.01
                    while !-f "$dir/$transport.closed" && time < $deadline;
                ok -f "$dir/$transport.closed", 'stream cancellation cleans up before the connection closes';
            }
        } else {
            $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1',
                PeerPort => $ports[$transport eq 'https' ? 1 : 0], Timeout => 5 * TMULT)
                or die 'connect failed';
            setsockopt($s, SOL_SOCKET, SO_RCVBUF, pack('i', 1024)) or die "rcvbuf: $!";
            IO::Socket::SSL->start_SSL($s,
                SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                SSL_alpn_protocols => ['http/1.1']) or die 'TLS failed' if $transport eq 'https';
            $s->syswrite("GET /$transport HTTP/1.1\r\nHost: x\r\n\r\n");
            $s->blocking(0);
            my $deadline = time + 3 * TMULT;
            my $wire = '';
            while ($wire !~ /\r\n\r\n/ && time < $deadline) {
                my $n = $s->sysread(my $bytes, 4096);
                $wire .= $bytes if defined $n && $n > 0;
                select undef, undef, undef, 0.01;
            }
            like $wire, qr/HTTP\/1\.1 200/, 'the file response has started';
        }
        setsockopt($s, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) or die "linger: $!";
        $transport eq 'http' ? close($s) : $s->close(SSL_no_shutdown => 1);
        my ($active, $deadline) = (undef, time + 2 * TMULT);
        while (time < $deadline) {
            if (open my $in, '<', "$dir/stats") {
                chomp($active = <$in> // 'missing');
                close $in;
                last if $active eq '0';
            }
            select undef, undef, undef, 0.02;
        }
        is $active, 0, 'the abandoned connection is released';
        # the report can land a loop tick after the polled stats reach 0
        $deadline = time + 2 * TMULT;
        select undef, undef, undef, 0.01
            while !-s "$dir/$transport.closed" && time < $deadline;
        my ($closes, $bytes);
        if (open my $in, '<', "$dir/$transport.closed") {
            ($closes, $bytes) = split ' ', <$in> // '';
            close $in;
        }
        is $closes, 1, 'close() runs exactly once after cancellation';
        cmp_ok $bytes // $size, '<', $size, 'cleanup runs before the file is fully read';
    };
}
done_testing;
