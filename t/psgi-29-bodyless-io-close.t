#!perl
# A HEAD or no-content response still runs its body's close(), and a source
# read error closes the body and finishes the response (HTTP, HTTPS, HTTP/2).
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
my $tls = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();
my $h2 = $tls && $probe->has_h2;
my $dir = tempdir(CLEANUP => 1);

{
    package CleanupBody;
    sub new { bless { report => $_[1], error => $_[2], reads => 0, closes => 0 }, $_[0] }
    sub getline {
        my $self = shift;
        my $previous = $self->{reads}++;
        die "simulated source read failure\n" if $self->{error};
        return $previous ? undef : 'BODY';
    }
    sub close {
        my $self = shift;
        $self->{closes}++;
        open my $out, '>', "$self->{report}.tmp" or die $!;
        print {$out} "$self->{reads} $self->{closes}\n";
        close $out;
        rename "$self->{report}.tmp", $self->{report} or die $!;
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
    if ($tls) {
        $f->set_tls(listener => 1, cert_file => 't/certs/alpha.crt',
                    key_file => 't/certs/alpha.key', h2 => $h2 ? 1 : 0);
    }
    $f->psgi_request_handler(sub {
        my $env = shift;
        my ($transport, $status, $error) = $env->{PATH_INFO} =~ m{^/(\w+)/(\d+)(/error)?$};
        my $report = "$dir/$transport-$status-$env->{REQUEST_METHOD}" . ($error ? '-error' : '');
        my $body = CleanupBody->new($report, $error);
        return [$status, ['Content-Type' => 'text/plain'], $body];
    });
    my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $_ for @listeners;

my @transports = ('http');
push @transports, 'https' if $tls;
push @transports, 'h2' if $h2;
for my $transport (@transports) {
    for my $case (['GET', 200], ['HEAD', 200], ['GET', 204], ['GET', 205], ['GET', 304],
                  ['GET', 200, 1]) {
        my ($method, $status, $error) = @$case;
        subtest "$transport $method $status" . ($error ? ' source error' : '') => sub {
            my $path = "/$transport/$status" . ($error ? '/error' : '');
            my $report = "$dir/$transport-$status-$method" . ($error ? '-error' : '');
            my ($s, $wire, $ended) = (undef, '', 0);
            if ($transport eq 'h2') {
                $s = h2_connect($ports[1]) or die 'H2 connect failed';
                $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 1,
                    hpack_encode_headers([':method', $method], [':scheme', 'https'],
                                         [':authority', 'x'], [':path', $path])));
                my $deadline = time + 3 * TMULT;
                while (time < $deadline) {
                    my $frame = h2_read_frame($s, 0.2) or next;
                    next unless $frame->{stream_id} == 1;
                    if ($error && $frame->{type} == H2_RST_STREAM) { $ended = 1; last }
                    $wire .= $frame->{payload} if $frame->{type} == H2_DATA;
                    if (($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
                        && ($frame->{flags} & FLAG_END_STREAM)) { $ended = 1; last }
                }
            } else {
                $s = $transport eq 'https' ? IO::Socket::SSL->new(
                    PeerAddr => '127.0.0.1', PeerPort => $ports[1],
                    SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
                    SSL_alpn_protocols => ['http/1.1'], Timeout => 5 * TMULT,
                ) : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $ports[0],
                                         Timeout => 5 * TMULT);
                die 'connect failed' unless $s;
                $s->syswrite("$method $path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
                $s->blocking(0);
                my $deadline = time + 3 * TMULT;
                while (time < $deadline) {
                    my $n = $s->sysread(my $bytes, 65536);
                    if (defined $n) {
                        if (!$n) { $ended = 1; last }
                        $wire .= $bytes;
                    } elsif (!$!{EAGAIN} && !$!{EWOULDBLOCK}) { last }
                    select undef, undef, undef, 0.01;
                }
            }
            ok $ended, 'the response completes';
            if (!$error && $method eq 'GET' && $status == 200) {
                like $wire, qr/BODY/, 'the ordinary body is delivered';
            } else {
                unlike $wire, qr/BODY/, 'no body content reaches the client';
            }
            # the server writes the report inside close(), just after the response;
            # allow the same budget as the response read so a loaded box does not race
            my $deadline = time + 3 * TMULT;
            select undef, undef, undef, 0.01 while !-f $report && time < $deadline;
            my ($reads, $closes);
            if (open my $in, '<', $report) {
                ($reads, $closes) = split ' ', <$in> // '';
                close $in;
            }
            is $closes, 1, 'close() releases the body resources exactly once';
            if ($error) {
                is $reads, 1, 'the failing read is attempted only once';
            } elsif ($method ne 'GET' || $status != 200) {
                is $reads, 0, 'suppressed content is never read';
            }
            close $s;
        };
    }
}
done_testing;
