#!perl
# The slowloris header deadline is re-armed for the 2nd and later requests on
# a keepalive connection, on both the plain and the TLS read paths, even after
# the peer idled past header_timeout between requests.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use IO::Socket::INET;

my $probe = Feersum->new_instance();
my $has_tls = $probe->has_tls() && eval { require IO::Socket::SSL; 1 }
              && -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';

# 3 per case: ok $socket + run_client's 2 (did-not-timeout, client-passed).
plan tests => $has_tls ? 6 : 3;

use constant HDR_TIMEOUT => 2 * TMULT;
# Under read_timeout, so only header_timeout can end the dribble.
use constant BYTE_GAP    => 0.8 * TMULT;

sub make_server {
    my ($tls) = @_;
    my ($socket, $port) = get_listen_socket();
    my $f = Feersum->new_instance();
    $f->use_socket($socket);
    $f->set_keepalive(1);
    $f->header_timeout(HDR_TIMEOUT);
    $f->read_timeout(30 * TMULT);
    $f->set_tls(cert_file => 'eg/ssl-proxy/server.crt',
                key_file  => 'eg/ssl-proxy/server.key') if $tls;
    $f->psgi_request_handler(sub {
        return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
    });
    return ($socket, $port);
}

# Returns 0 if the server cut the dribbled second request off, 1 if it did not.
sub dribble_survives {
    my ($port, $tls) = @_;
    my $s;
    if ($tls) {
        $s = IO::Socket::SSL->new(
            PeerAddr => "127.0.0.1:$port",
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            Timeout => 10 * TMULT) or return -1;
    }
    else {
        $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                   Timeout => 10 * TMULT) or return -1;
    }

    syswrite($s, "GET /one HTTP/1.1\015\012Host: l\015\012\015\012") or return -1;
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 8 * TMULT;
        while ($r !~ /\015\012\015\012ok/s) {
            my $n = sysread($s, my $b, 4096);
            last unless $n;
            $r .= $b;
        }
        alarm 0;
    };
    return -1 unless $r =~ /ok/;

    # Idle past header_timeout so the one-shot armed at the keepalive reset
    # fires and is consumed while we are in RECEIVE_WAIT.
    select undef, undef, undef, HDR_TIMEOUT + 1;

    my $deadline = time + (5 * HDR_TIMEOUT) + 4;
    for my $ch (split //, "GET /two HTTP/1.1\015\012Host: localhost\015\012\015\012") {
        return 0 unless syswrite($s, $ch);   # cut off: the deadline fired
        select undef, undef, undef, BYTE_GAP;
        return 1 if time > $deadline;        # still alive well past any deadline
    }
    return 1;
}

for my $case ([0, 'plain'], [1, 'TLS']) {
    my ($tls, $name) = @$case;
    next if $tls && !$has_tls;

    my ($socket, $port) = make_server($tls);
    ok $socket, "$name: listen on $port";

    run_client("$name-keepalive-header-deadline", sub {
        my $survived = dribble_survives($port, $tls);
        return 11 if $survived < 0;   # setup failed
        return 12 if $survived;       # pre-fix on TLS: dribbles forever
        return 0;
    });
}
