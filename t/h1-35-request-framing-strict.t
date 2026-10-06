#!perl
# Malformed framing must be refused before dispatch, including when a second
# request is already buffered. Exercise the shared parser over plain and TLS.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;
use POSIX ();

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);

my $probe = Feersum->new_instance;
my @transports = ('plain');
push @transports, 'tls' if $probe->has_tls
    && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

for my $transport (@transports) {
    subtest $transport => sub {
        my ($listen, $port) = get_listen_socket();
        die "listen: $!" unless $listen;
        my $pid = fork;
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            $SIG{QUIT} = 'DEFAULT';
            my $f = Feersum->new_instance;
            $f->use_socket($listen);
            $f->set_keepalive(1);
            $f->linger_timeout(0);
            $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key')
                if $transport eq 'tls';
            $f->psgi_request_handler(sub {
                my $env = shift;
                my $body = '';
                $env->{'psgi.input'}->read($body, $env->{CONTENT_LENGTH});
                return [200, [], ["accepted:$env->{PATH_INFO}:$body"]];
            });
            my $life = EV::timer(30 * TMULT, 0, sub { POSIX::_exit(0) });
            EV::run;
            POSIX::_exit(0);
        }
        my $cleanup = guard { reap_server($pid) };
        close $listen;

        my $exchange = sub {
            my ($header, $body, $version) = @_;
            $version ||= '1.1';
            my $s = $transport eq 'tls'
                ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
                    SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(), Timeout => 5 * TMULT)
                : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 5 * TMULT);
            die "connect: $!" unless $s;
            my $request = "POST /first HTTP/$version\r\nHost: x\r\n$header\r\n\r\n$body"
                        . "GET /after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            my $response = '';
            eval {
                local $SIG{ALRM} = sub { die "request timeout\n" };
                alarm 5 * TMULT;
                my $offset = 0;
                while ($offset < length $request) {
                    my $n = syswrite($s, $request, length($request) - $offset, $offset);
                    die "write: $!" unless $n;
                    $offset += $n;
                }
                while (sysread($s, my $part, 65536)) { $response .= $part }
                alarm 0;
                1;
            } or do { alarm 0; diag $@ };
            close $s;
            return $response;
        };

        for my $value ('0 but true', '+0', '1.0', '1e0', '0, 0', '18446744073709551616') {
            my $response = $exchange->("Content-Length: $value", '');
            like $response, qr/\AHTTP\/1\.1 400\b/, "reject Content-Length: $value";
            unlike $response, qr/accepted:/, 'neither request reaches the app';
        }
        for my $case (["Content-Length: \t0004 \t", 'DATA'],
                      ['Transfer-Encoding: ChUnKeD', "4\r\nDATA\r\n0\r\n\r\n"]) {
            my $response = $exchange->(@$case);
            like $response, qr/accepted:\/first:DATA/, 'valid framing preserves the body';
            like $response, qr/accepted:\/after:/, 'valid framing preserves the pipeline';
        }
        for my $version ('1.1', '1.0') {
            for my $connection ("Connection: keep-alive, ClOsE",
                                "Connection: close\r\nConnection: keep-alive",
                                "Connection: keep-alive\r\nConnection: close") {
                my $response = $exchange->("Content-Length: 0\r\n$connection", '', $version);
                like $response, qr/accepted:\/first:/, "HTTP/$version accepts the first request";
                my ($head) = split /\r\n\r\n/, $response, 2;
                if ($version eq '1.1') {
                    like $head, qr/(?:\A|\r\n)Connection: close(?:\r\n|\z)/i,
                        'close wins in token lists and repeated fields';
                } else {
                    unlike $head, qr/(?:\A|\r\n)Connection: keep-alive(?:\r\n|\z)/i,
                        'HTTP/1.0 retains its default close semantics';
                }
                unlike $response, qr/accepted:\/after:/, 'close prevents dispatch of the pipelined request';
            }
        }

        undef $cleanup;
        done_testing;
    };
}
done_testing;
