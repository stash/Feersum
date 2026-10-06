#!perl
# The request target's :authority must determine HTTP_HOST, even if a
# separate Host field names a different virtual host.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

sub request_frame {
    my ($id, $authority, $host, $connect) = @_;
    my @headers = ([':method', $connect ? 'CONNECT' : 'GET'], [':scheme', 'https']);
    push @headers, [':authority', $authority] if defined $authority;
    push @headers, [':path', '/host'];
    push @headers, [':protocol', 'websocket'] if $connect;
    push @headers, ['host', $host] if defined $host;
    return h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, $id,
        hpack_encode_headers(@headers));
}

sub read_response {
    my ($sock, $id) = @_;
    my ($status, $body, $ended, $reset) = (undef, '', 0, 0);
    my $deadline = time + 3 * TMULT;
    while (time < $deadline && !$ended && !$reset) {
        my $frame = h2_read_frame($sock, 0.1) or next;
        next unless $frame->{stream_id} == $id;
        $status = hpack_decode_status($frame->{payload}) if $frame->{type} == H2_HEADERS;
        $body .= $frame->{payload} if $frame->{type} == H2_DATA;
        $reset = 1 if $frame->{type} == H2_RST_STREAM;
        $ended = 1 if ($frame->{type} == H2_HEADERS || $frame->{type} == H2_DATA)
            && ($frame->{flags} & FLAG_END_STREAM);
    }
    return ($status, $body, $ended, $reset);
}

for my $api ('psgi', 'native') {
    subtest $api => sub {
        my ($listen, $port) = get_listen_socket();
        die "listen: $!" unless $listen;
        my $pid = fork;
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            $SIG{QUIT} = 'DEFAULT';
            EV::now_update();
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
            if ($api eq 'psgi') {
                $f->psgi_request_handler(sub {
                    my $env = shift;
                    return [$env->{'psgix.h2.extended_connect'} ? 403 : 200,
                        ['Content-Type' => 'text/plain'], [$env->{HTTP_HOST} // 'missing']];
                });
            } else {
                $f->request_handler(sub {
                    my $req = shift;
                    my $env = $req->env;
                    $req->send_response($env->{'psgix.h2.extended_connect'} ? 403 : 200,
                        ['Content-Type' => 'text/plain'], $env->{HTTP_HOST} // 'missing');
                });
            }
            my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(1) });
            EV::run;
            POSIX::_exit(0);
        }
        my $cleanup = guard { reap_server($pid) };
        close $listen;

        for my $case (
            ['authority only', 'route.example:8443', undef, 0],
            ['matching Host', 'route.example', 'route.example', 0],
            ['conflicting Host', 'route.example', 'other.example', 0],
            ['equivalent Host spelling', 'Route.Example:443', 'route.example', 0],
            ['IPv6 authority', '[::1]:8443', '[2001:db8::1]:443', 0],
            ['Host fallback', undef, 'fallback.example', 0],
            ['Extended CONNECT', 'route.example:8443', 'other.example:8443', 1],
        ) {
            my ($label, $authority, $host, $connect) = @$case;
            subtest $label => sub {
                my $sock = h2_connect($port) or die 'H2 connect failed';
                my $request = request_frame(1, $authority, $host, $connect);
                is $sock->syswrite($request), length($request), 'request sent';
                my ($status, $body, $ended, $reset) = read_response($sock, 1);
                is $status, $connect ? 403 : 200, 'application answers the request';
                is $body, $authority // $host, 'HTTP_HOST comes from the request authority';
                ok $ended && !$reset, 'response completes without a reset';

                $request = request_frame(3, 'next.example', 'wrong-next.example', 0);
                is $sock->syswrite($request), length($request), 'next request sent';
                ($status, $body, $ended, $reset) = read_response($sock, 3);
                is $status, 200, 'connection remains usable';
                is $body, 'next.example', 'next stream has its own authority';
                ok $ended && !$reset, 'next response completes';
                $sock->close;
            };
        }
        done_testing;
    };
}
done_testing;
