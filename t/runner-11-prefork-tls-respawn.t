#!perl
# A replacement worker respawned by a pre-forking supervisor without
# SO_REUSEPORT still serves TLS on the TLS listener and reports the listener's
# SERVER_NAME/SERVER_PORT, since the parent re-arms its listeners around fork.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;
use POSIX ();

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    eval { require IO::Socket::SSL; 1 }
        or plan skip_all => "IO::Socket::SSL not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan tests => 6;
}

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "test certs not found" unless -f $cert && -f $key;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my (undef, $port) = get_listen_socket();

my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen   => ["localhost:$port"],
            pre_fork => 1,
            # Retire after two requests so the third is served by a worker that
            # was forked *after* the parent's first unlisten().
            max_requests_per_worker => 2,
            tls      => { cert_file => $cert, key_file => $key },
            app      => sub {
                my $r = shift;
                my $e = $r->env;
                $r->send_response(200, ['Content-Type' => 'text/plain'],
                    ["name=$e->{SERVER_NAME} port=$e->{SERVER_PORT}"]);
            },
            quiet    => 1,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 2.5 * TIMEOUT_MULT;

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/116 watchdog timeout\n" };
alarm 90 * TIMEOUT_MULT;

# Each element: [handshake_ok, body]
my @got;
for my $i (1 .. 4) {
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => "127.0.0.1:$port",
        SSL_verify_mode => 0,
        Timeout         => 5 * TIMEOUT_MULT,
    );
    if (!$cl) { push @got, [0, '']; next }
    print $cl "GET /$i HTTP/1.0\r\n\r\n";
    my $resp = do { local $/; <$cl> };
    close $cl;
    my ($body) = ($resp || '') =~ m{\r\n\r\n(.*)}s;
    push @got, [1, defined $body ? $body : ''];
    select undef, undef, undef, 0.6 * TIMEOUT_MULT;
}

alarm 0;
reap_server($pid);

ok $got[0][0] && $got[1][0], "cold-start worker completes TLS handshakes";

# The load-bearing assertions: requests 3 and 4 hit a respawned worker.
ok $got[2][0], "respawned worker still speaks TLS (request 3)";
ok $got[3][0], "respawned worker still speaks TLS (request 4)";

like $got[2][1], qr/\bname=\S+/,
    "respawned worker reports a non-empty SERVER_NAME";
unlike $got[2][1], qr/\bport=0\b/,
    "respawned worker reports the real SERVER_PORT, not 0";

is $got[2][1], $got[0][1],
    "respawned worker sees the same SERVER_NAME/SERVER_PORT as the first";
