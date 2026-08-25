#!perl
# Verify SNI config propagates correctly through Feersum::Runner
# (end-to-end: Runner.pm sni option -> _apply_tls_to_listeners -> set_tls)
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
    plan tests => 5;
}

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $alpha_cert = 't/certs/alpha.crt';
my $alpha_key  = 't/certs/alpha.key';
my $beta_cert  = 't/certs/beta.crt';
my $beta_key   = 't/certs/beta.key';

for ($alpha_cert, $alpha_key, $beta_cert, $beta_key) {
    plan skip_all => "test certs not found ($_)" unless -f $_;
}

my (undef, $port) = get_listen_socket();

sub get_cert_cn {
    my ($port, $hostname) = @_;
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => "127.0.0.1:$port",
        SSL_hostname    => $hostname,
        SSL_verify_mode => 0,
        Timeout         => 3 * TIMEOUT_MULT,
    ) or return undef;
    my $cn = $cl->peer_certificate('cn');
    print $cl "GET / HTTP/1.0\r\nHost: $hostname\r\n\r\n";
    local $/; my $resp = <$cl>;
    close $cl;
    return $cn;
}

my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    require Feersum::Runner;
    eval {
        my $runner = Feersum::Runner->new(
            listen => ["localhost:$port"],
            tls    => { cert_file => $alpha_cert, key_file => $alpha_key },
            sni    => [
                { sni => 'beta.local', cert_file => $beta_cert, key_file => $beta_key },
            ],
            app    => sub {
                my $r = shift;
                $r->send_response(200, ['Content-Type' => 'text/plain'], \"ok\n");
            },
            quiet  => 1,
        );
        $runner->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 1.5 * TIMEOUT_MULT;

# Watchdog: if the forked Runner hangs (never binds, deadlocks), don't let
# the parent block forever on connects + waitpid and stall the CI smoker.
local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/39b watchdog timeout\n" };
alarm 60 * TIMEOUT_MULT;

my $cn1 = get_cert_cn($port, 'alpha.local');
is $cn1, 'alpha.local', "Runner sni: default cert for alpha.local";

my $cn2 = get_cert_cn($port, 'beta.local');
is $cn2, 'beta.local',  "Runner sni: matching cert for beta.local";

my $cn3 = get_cert_cn($port, 'unknown.local');
is $cn3, 'alpha.local', "Runner sni: fallback to default for unknown";

ok $cn1 && $cn2 && $cn3, "all connections succeeded";

alarm 0;
reap_server($pid);
# $? was discarded, so a Runner that dumped core during shutdown still
# "passed".  Assert it exited without a signal.
is $? & 127, 0, "Runner + sni exited without a signal";
