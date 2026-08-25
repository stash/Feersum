#!perl
# Plain TCP + TLS(+SNI) + UNIX listeners on ONE server instance.  Each of the
# three transports is covered separately elsewhere, but nothing exercised them
# together, which is where per-listener state would leak into its neighbours.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use IO::Socket::INET;
use IO::Socket::UNIX;
use File::Temp qw(tempdir);
use POSIX ();
use lib 't'; use Utils;
use Feersum;

my $evh = Feersum->new();
plan skip_all => 'Feersum not compiled with TLS support' unless $evh->has_tls();

my ($alpha_cert, $alpha_key) = ('t/certs/alpha.crt', 't/certs/alpha.key');
my ($beta_cert,  $beta_key)  = ('t/certs/beta.crt',  't/certs/beta.key');
plan skip_all => 'no test certificates'
    unless -f $alpha_cert && -f $alpha_key && -f $beta_cert && -f $beta_key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 15;

my $tmpdir = tempdir(CLEANUP => 1);
my $upath  = "$tmpdir/mixed.sock";

my ($plain_sock, $plain_port) = get_listen_socket();
ok $plain_sock, "plain listen socket on port $plain_port";
my ($tls_sock, $tls_port) = get_listen_socket();
ok $tls_sock, "TLS listen socket on port $tls_port";
my $unix_sock = IO::Socket::UNIX->new(Local => $upath, Listen => 128);
ok $unix_sock, 'UNIX listen socket';
$unix_sock->blocking(0);

$evh->use_socket($plain_sock);   # listener 0
$evh->use_socket($tls_sock);     # listener 1
$evh->use_socket($unix_sock);    # listener 2

eval { $evh->set_tls(listener => 1, cert_file => $alpha_cert, key_file => $alpha_key) };
is $@, q{}, 'set_tls default cert on listener 1 only';
eval { $evh->set_tls(listener => 1, sni => 'beta.local',
                     cert_file => $beta_cert, key_file => $beta_key) };
is $@, q{}, 'set_tls SNI entry on listener 1';

$evh->psgi_request_handler(sub {
    my $env = shift;
    my $body = join q{|}, map { "$_=" . (defined $env->{$_} ? $env->{$_} : 'undef') }
                          qw(SERVER_NAME SERVER_PORT psgi.url_scheme);
    return [200, ['Content-Type' => 'text/plain'], [$body]];
});

# All three clients run as concurrent children writing to files; the parent
# must stay inside the event loop or the in-process server can never answer.
my %kid;
for my $t (
    ['plain', sub { IO::Socket::INET->new(PeerAddr => "127.0.0.1:$plain_port",
                                          Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT) }],
    ['unix',  sub { IO::Socket::UNIX->new(Peer => $upath) }],
    ['tls',   sub { IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$tls_port",
                                         SSL_hostname => 'beta.local',
                                         SSL_verify_mode => 0,
                                         Timeout => 5 * TIMEOUT_MULT) }],
) {
    my ($name, $make_sock) = @$t;
    my $out_file = "$tmpdir/$name.out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        select undef, undef, undef, 0.3 * TIMEOUT_MULT;
        my $buf = 'CONNFAIL';
        my $s = eval { $make_sock->() };
        if ($s) {
            syswrite $s, "GET /x HTTP/1.1\r\nHost: probe.example\r\nConnection: close\r\n\r\n";
            $buf = q{};
            my $g;
            while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
            close $s;
        }
        $buf =~ s/\r?\n/ /g;
        if (open my $fh, '>', $out_file) { print {$fh} $buf; close $fh }
        POSIX::_exit(0);
    }
    $kid{$name} = { pid => $pid, file => $out_file };
}

my $cv = AnyEvent->condvar;
my $left = scalar keys %kid;
my @watchers = map {
    my $n = $_;
    AnyEvent->child(pid => $kid{$n}{pid}, cb => sub { $cv->send if --$left <= 0 });
} keys %kid;
my $guard = AnyEvent->timer(after => 30 * TIMEOUT_MULT, cb => sub { $cv->send });
$cv->recv;
undef @watchers; undef $guard;

my %out;
for my $n (keys %kid) {
    waitpid $kid{$n}{pid}, 0;
    open my $fh, '<', $kid{$n}{file} or next;
    $out{$n} = do { local $/; <$fh> };
    close $fh;
}

is scalar(grep { defined && length } values %out), 3, 'all three transports answered';

my ($plain_out, $unix_out, $tls_out) = map { $out{$_} // q{} } qw(plain unix tls);

like $plain_out, qr{^HTTP/1\.1\ 200}x, 'plain listener: 200';
like $plain_out, qr/SERVER_PORT=$plain_port/, 'plain listener: own port in env';
like $plain_out, qr{psgi\.url_scheme=http\b}, 'plain listener: scheme http';

like $unix_out, qr{^HTTP/1\.1\ 200}x, 'UNIX listener: 200';
like $unix_out, qr/SERVER_NAME=unix/, 'UNIX listener: SERVER_NAME=unix';
like $unix_out, qr{psgi\.url_scheme=http\b}, 'UNIX listener: scheme http';

like $tls_out, qr{^HTTP/1\.1\ 200}x, 'TLS listener: 200';
like $tls_out, qr/SERVER_PORT=$tls_port/, 'TLS listener: own port in env';
like $tls_out, qr{psgi\.url_scheme=https\b},
    'TLS listener: scheme https (not leaked from the plain listener)';
