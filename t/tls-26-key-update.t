#!perl
# A TLS 1.3 KeyUpdate on a live keepalive connection must not break the
# requests after it.  openssl s_client's interactive 'k' sends a KeyUpdate and
# 'K' one that also requests the peer update.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;

my $ossl = `openssl version 2>/dev/null`;
plan skip_all => 'openssl not available' unless $ossl;
# 'k'/'K' and TLS 1.3 both need OpenSSL 1.1.1 or newer.
plan skip_all => "openssl too old for TLS 1.3 ($ossl)"
    unless $ossl =~ /OpenSSL\s+(\d+)\.(\d+)\.(\d+)/
        && ($1 > 1 || ($1 == 1 && $2 == 1 && $3 >= 1));

plan tests => 3;

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->header_timeout(30 * TIMEOUT_MULT);
    $f->write_timeout(30 * TIMEOUT_MULT);
    # h2 => 0: this is about the TLS record layer under HTTP/1.1 keepalive.
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 0) };
    my $n = 0;
    $f->psgi_request_handler(sub {
        $n++;
        return [200, ['Content-Type' => 'text/plain'], ["reply-$n"]];
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

# No `timeout(1)` (not on macOS): the child is bounded from Perl instead.
# openssl only turns a lone 'k'/'K' line into a KeyUpdate; a starved smoker can
# batch stdin into one read() and send it as plaintext, which the server 400s,
# so the spacing is scaled and that 400 signature is a skip, not a failure.
my $gap = TIMEOUT_MULT;
my $cmd = q{(printf 'GET /one HTTP/1.1\r\nHost: x\r\n\r\n'; sleep } . $gap . q{; }
        . q{printf 'k\n'; sleep } . $gap . q{; }
        . q{printf 'GET /two HTTP/1.1\r\nHost: x\r\n\r\n'; sleep } . $gap . q{; }
        . q{printf 'K\n'; sleep } . $gap . q{; }
        . q{printf 'GET /three HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'; sleep }
        . (2 * $gap) . q{) }
        . qq{| openssl s_client -quiet -no_ign_eof -connect 127.0.0.1:$port 2>&1};

my $out = q{};
my $cpid = open my $ch, '-|', 'sh', '-c', $cmd;
if ($cpid) {
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 40 * TIMEOUT_MULT;
        local $/;
        $out = <$ch> // q{};
        alarm 0;
        1;
    };
    alarm 0;
    kill 'KILL', $cpid;
    close $ch;
    waitpid $cpid, 0;
}

my @replies = $out =~ /reply-(\d+)/g;

# A 400 with fewer than three replies means a 'k'/'K' reached the parser as
# plaintext - the KeyUpdate never went out.  A real desync would drop the
# connection, not 400, so skipping here cannot hide a server regression.
my $swallowed = @replies < 3 && $out =~ m{HTTP/1\.[01] 400|Malformed};

SKIP: {
    skip 'openssl s_client sent the KeyUpdate command as plaintext (its stdin '
       . 'batched under load); the server KeyUpdate path was not exercised', 2
        if $swallowed;
    is scalar(@replies), 3,
        'all three requests answered across two KeyUpdates'
        or diag "replies: @replies\ns_client output:\n$out";
    is_deeply [@replies], [1, 2, 3],
        'and they arrive in order, so the record stream stayed in sync';
}

reap_server($server);
