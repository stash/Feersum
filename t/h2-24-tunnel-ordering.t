#!perl
# The H2 Extended CONNECT tunnel delivers the stream to the app in order: a new
# write must not overtake an undrained remainder from an earlier short write.
# Every record carries its own index - a length check alone would miss a swap.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use AnyEvent;
use H2Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
plan skip_all => 'Feersum not compiled with H2 support'  unless $probe->has_h2();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 4;

my $REC     = 16;
my $RECORDS = 25000;
my $dir     = tempdir(CLEANUP => 1);
my $resfile = "$dir/result";

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', "$dir/err";
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 1) };
    my %keep;
    $f->psgi_request_handler(sub {
        my $env = shift;
        return sub {
            my $responder = shift;
            my $writer = $responder->([200, ['X-Tunnel' => 'accepted']]);
            my $io = $env->{'psgix.io'};
            unless ($io && ref $io) { $writer->close; return }
            my $id = 0 + $io;
            my ($buf, $next, $bad, $seen) = ('', 0, 0, 0);
            # Small sips, so the socketpair repeatedly fills and drains.
            my $w;
            $w = EV::io $io, EV::READ, sub {
                my $n = sysread $io, my $z, 4096;
                return unless defined $n;
                if ($n == 0) {
                    if (open my $r, '>', $resfile) {
                        print {$r} "seen=$seen bad=$bad\n";
                        close $r;
                    }
                    undef $w;
                    delete $keep{$id};
                    return;
                }
                $buf .= $z;
                while (length($buf) >= $REC) {
                    my $rec = substr($buf, 0, $REC, '');
                    $seen++;
                    my ($idx) = $rec =~ /^(\d{10})/;
                    if (!defined $idx) { $bad++; next }
                    $bad++ if $idx != $next;
                    $next = $idx + 1;
                }
            };
            $keep{$id} = [$io, $writer, \$w];
        };
    });
    my $life_timer = EV::timer(180 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

my $s = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
    SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
    SSL_alpn_protocols => ['h2'], Timeout => 15 * TIMEOUT_MULT);
ok $s, 'H2 client connected';

my $sent = 0;
my $accepted = 0;
if ($s) {
    $s->syswrite("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" . h2_frame(H2_SETTINGS, 0, 0, ''));
    $s->blocking(0);
    my $deadline = time + 6 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $f = h2_read_frame($s, 1) or last;
        if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
            $s->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
            last;
        }
    }
    my $hdrs = hpack_encode_headers([':method', 'CONNECT'],
        [':protocol', 'websocket'], [':path', '/tunnel'], [':scheme', 'https'],
        [':authority', "127.0.0.1:$port"]);
    $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS, 1, $hdrs));
    my $t0 = time;
    while (time - $t0 < 10 * TIMEOUT_MULT) {
        my $f = h2_read_frame($s, 0.3) or next;
        if ($f->{type} == H2_HEADERS) { $accepted = 1; last }
        last if $f->{type} == H2_RST_STREAM || $f->{type} == H2_GOAWAY;
    }

    if ($accepted) {
        $s->blocking(1);
        my $push = sub {
            my ($payload) = @_;
            my $fr = h2_frame(H2_DATA, 0, 1, $payload);
            my $off = 0;
            while ($off < length $fr) {
                my $n = syswrite $s, substr($fr, $off);
                last if !defined $n;
                $off += $n;
            }
        };
        eval {
            local $SIG{ALRM} = sub { die "to\n" };
            alarm 150 * TIMEOUT_MULT;
            my $batch = '';
            for my $i (0 .. $RECORDS - 1) {
                $batch .= sprintf('%010d', $i) . '......';
                $sent++;
                if (length($batch) >= 8192) { $push->($batch); $batch = '' }
            }
            $push->($batch) if length $batch;
            alarm 0;
            1;
        };
        alarm 0;
        select undef, undef, undef, 4 * TIMEOUT_MULT;   # let the tunnel drain
    }
    close $s;
    select undef, undef, undef, 2 * TIMEOUT_MULT;
}

my %v;
if (open my $r, '<', $resfile) {
    my $line = <$r>;
    close $r;
    chomp $line if defined $line;
    %v = map { my ($k, $x) = split /=/; ($k => $x) } split / /, ($line // q{});
}
reap_server($server);

is $v{bad} // -1, 0,
    sprintf('the H2 tunnel never reorders: %s records read, %s out of sequence',
            $v{seen} // '(none)', $v{bad} // '(no report)');
is $v{seen} // -1, $sent,
    sprintf('and every record arrives (%s of %d)', $v{seen} // '(none)', $sent);
