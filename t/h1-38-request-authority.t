#!perl
# An absolute-form request's authority must determine HTTP_HOST, including
# when a conflicting Host field is sent over a plain or TLS connection.
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

sub connect_client {
    my ($transport, $port) = @_;
    return $transport eq 'tls'
        ? IO::Socket::SSL->new(PeerAddr => '127.0.0.1', PeerPort => $port,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(), Timeout => 3 * TMULT)
        : IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 3 * TMULT);
}

sub read_response {
    my $sock = shift;
    my ($status, $body);
    eval {
        local $SIG{ALRM} = sub { die "response timeout\n" };
        alarm 3 * TMULT;
        my $headers = '';
        while ($headers !~ /\r\n\r\n\z/) {
            die "missing headers\n" unless $sock->sysread(my $byte, 1);
            $headers .= $byte;
            die "oversized headers\n" if length($headers) > 65536;
        }
        ($status) = $headers =~ /\AHTTP\/1\.1 (\d{3})\b/;
        my ($length) = $headers =~ /\r\nContent-Length: (\d+)\r\n/i;
        die "missing body length\n" unless defined $length;
        $body = '';
        while (length($body) < $length) {
            die "missing body\n" unless $sock->sysread(my $part, $length - length($body));
            $body .= $part;
        }
        alarm 0;
        1;
    } or do { alarm 0; diag $@; $body = undef };
    return ($status, $body);
}

for my $transport (@transports) {
    for my $api ('psgi', 'native') {
        subtest "$transport $api" => sub {
            my ($listen, $port) = get_listen_socket();
            die "listen: $!" unless $listen;
            my $pid = fork;
            die "fork: $!" unless defined $pid;
            if (!$pid) {
                $SIG{QUIT} = 'DEFAULT';
                EV::now_update();
                my $f = Feersum->new_instance;
                $f->use_socket($listen);
                $f->set_keepalive(1);
                $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 0)
                    if $transport eq 'tls';
                my $describe = sub {
                    my $env = shift;
                    return join "\n", map { $env->{$_} // 'missing' }
                        qw(HTTP_HOST PATH_INFO QUERY_STRING REQUEST_URI);
                };
                if ($api eq 'psgi') {
                    $f->psgi_request_handler(sub {
                        return [200, ['Content-Type' => 'text/plain'], [$describe->(shift)]];
                    });
                } else {
                    $f->request_handler(sub {
                        my $req = shift;
                        $req->send_response(200, ['Content-Type' => 'text/plain'], $describe->($req->env));
                    });
                }
                my $life = EV::timer(60 * TMULT, 0, sub { POSIX::_exit(1) });
                EV::run;
                POSIX::_exit(0);
            }
            my $cleanup = guard { reap_server($pid) };
            close $listen;

            for my $case (
                ['http://route.example/path', 'route.example', '/path', ''],
                ['https://Route.Example:8443/a%20b?x=1', 'Route.Example:8443', '/a b', 'x=1'],
                ['http://route.example', 'route.example', '/', ''],
                ['http://route.example?x=1', 'route.example', '/', 'x=1'],
                ['http://[::1]:8080/path', '[::1]:8080', '/path', ''],
                ['http://user@route.example/path', 'route.example', '/path', ''],
                ['http://user:pass@route.example:8080/p?x=1', 'route.example:8080', '/p', 'x=1'],
                ['http://user@[::1]:8080/path', '[::1]:8080', '/path', ''],
                ['/origin?x=1', 'other.example', '/origin', 'x=1'],
                ['*', 'other.example', '*', ''],
            ) {
                my ($target, $host, $path, $query) = @$case;
                subtest $target => sub {
                    my $sock = connect_client($transport, $port) or die "connect: $!";
                    my $method = $target eq '*' ? 'OPTIONS' : 'GET';
                    my $request = "$method $target HTTP/1.1\r\nHost: other.example\r\nConnection: close\r\n\r\n";
                    is $sock->syswrite($request), length($request), 'request sent';
                    my ($status, $body) = read_response($sock);
                    is $status, 200, 'application answers the request';
                    is $body, join("\n", $host, $path, $query, $target),
                        'authority, path, query and raw target agree';
                    $sock->close;
                };
            }

            my $sock = connect_client($transport, $port) or die "connect: $!";
            my $request = "GET http://first.example/first HTTP/1.1\r\nHost: other.example\r\n\r\n"
                . "GET /second HTTP/1.1\r\nHost: second.example\r\nConnection: close\r\n\r\n";
            is $sock->syswrite($request), length($request), 'pipelined requests sent';
            my ($status, $body) = read_response($sock);
            is $status, 200, 'absolute-form request answers on a reused connection';
            is $body, "first.example\n/first\n\nhttp://first.example/first", 'first request uses its authority';
            ($status, $body) = read_response($sock);
            is $status, 200, 'pipelined origin-form request answers';
            is $body, "second.example\n/second\n\n/second", 'next request uses its own Host';
            $sock->close;
            done_testing;
        };
    }
}
done_testing;
