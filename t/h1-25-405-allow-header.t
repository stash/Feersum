#!perl
# RFC 9110 15.5.6: a 405 carries an Allow header naming the supported methods,
# on both the plain and the TLS read path.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use Feersum;

my $probe = Feersum->new();
my $has_tls = $probe->has_tls();
my ($cert, $key) = ('t/certs/alpha.crt', 't/certs/alpha.key');
my $tls_ok = $has_tls && -f $cert && -f $key
          && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

plan tests => $tls_ok ? 10 : 8;

my ($plain_sock, $plain_port) = get_listen_socket();
ok $plain_sock, "plain listen socket on port $plain_port";
my ($tls_sock, $tls_port) = $tls_ok ? get_listen_socket() : (undef, undef);

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    my $f = Feersum->new();
    $f->use_socket($plain_sock);
    if ($tls_ok) {
        $f->use_socket($tls_sock);
        $f->set_tls(listener => 1, cert_file => $cert, key_file => $key);
    }
    $f->read_timeout(15 * TIMEOUT_MULT);
    $f->header_timeout(15 * TIMEOUT_MULT);
    $f->max_uri_len(64);
    $f->psgi_request_handler(sub {
        return [200, ['Content-Type' => 'text/plain'], ['ok']];
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $plain_sock;
close $tls_sock if $tls_sock;

# Each request runs in a child so the parent stays in the event loop.
sub fetch {
    my ($port, $line, $tls) = @_;
    my $pid = open my $kid, '-|';
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        my $s = $tls
            ? IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
                                   SSL_verify_mode => 0, Timeout => 8 * TIMEOUT_MULT)
            : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                    Timeout => 8 * TIMEOUT_MULT);
        if (!$s) { print "NOSOCK\n"; POSIX::_exit(0) }
        syswrite $s, "$line HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        my ($buf, $g) = (q{});
        while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
        close $s;
        my ($st) = $buf =~ m{^HTTP/1\.\d\ (\d{3})}x;
        my ($al) = $buf =~ /^Allow:[ ]*(.+?)\r?$/mi;
        printf "%s\t%s\n", $st // 'none', defined $al ? $al : q{};
        POSIX::_exit(0);
    }
    my $out = do { local $/; <$kid> };
    close $kid;
    waitpid $pid, 0;
    chomp $out if defined $out;
    my ($st, $al) = split /\t/, ($out // q{}), 2;
    return ($st // 'none', (defined $al && length $al) ? $al : undef);
}

my @EXPECTED = qw(GET HEAD POST PUT PATCH DELETE OPTIONS);

my ($st, $allow) = fetch($plain_port, 'PROPFIND /a', 0);
is $st, '405', 'plain: unknown method gets 405';
ok defined($allow), 'plain: 405 carries an Allow header' or diag 'no Allow header';
if (defined $allow) {
    my @got = grep { length } map { s/^\s+|\s+$//gr } split /,/, $allow;
    is_deeply [sort @got], [sort @EXPECTED],
        "plain: Allow lists the supported methods ($allow)";
}
else {
    fail 'plain: Allow lists the supported methods';
}

# A 405 is the only status that should name a method set.
my ($st200, $allow200) = fetch($plain_port, 'GET /a', 0);
is $st200, '200', 'plain: a normal request still succeeds';
ok !defined($allow200), 'plain: a 200 carries no Allow header';

my ($st414, $allow414) = fetch($plain_port, 'GET /' . ('z' x 300), 0);
is $st414, '414', 'plain: over-long URI gets 414';
ok !defined($allow414), 'plain: a 414 carries no Allow header';

if ($tls_ok) {
    my ($tst, $tallow) = fetch($tls_port, 'PROPFIND /a', 1);
    is $tst, '405', 'TLS twin: unknown method gets 405';
    ok defined($tallow) && $tallow eq ($allow // q{}),
        'TLS twin: same Allow header as the plain transport'
        or diag 'tls=' . (defined $tallow ? $tallow : '(none)')
              . ' plain=' . (defined $allow ? $allow : '(none)');
}

reap_server($server);
