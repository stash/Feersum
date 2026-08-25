#!perl
# Middleware that assigns to PSGI env values must work end to end: this drives
# Plack::Middleware::ReverseProxy plus a revisor for the keys no shipped
# middleware touches (t/136 covers assignability directly).
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();

BEGIN {
    eval { require Plack::Middleware::ReverseProxy; 1 }
        or plan skip_all => 'Plack::Middleware::ReverseProxy not installed';
    plan tests => 7;
}

use Feersum;

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my @REPORT = qw(REMOTE_ADDR SERVER_PORT HTTP_HOST SCRIPT_NAME PATH_INFO
                psgi.url_scheme X_CUSTOM);

my $server = fork // die "fork: $!";
if (!$server) {
    $SIG{QUIT} = 'DEFAULT';
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->read_timeout(15 * TIMEOUT_MULT);
    $f->set_keepalive(1);
    # Report what the app actually received, so the parent can check it.
    my $app = sub {
        my $env = shift;
        my $body = join "\n", map { "$_=" . ($env->{$_} // '') } @REPORT;
        return [200, ['Content-Type' => 'text/plain'], [$body]];
    };
    my $proxied = Plack::Middleware::ReverseProxy->wrap($app);
    $f->psgi_request_handler(sub {
        my $env = shift;
        # /revise exercises assignment to keys no shipped middleware rewrites.
        if (($env->{PATH_INFO} // '') eq '/revise') {
            $env->{SCRIPT_NAME} = '/myapp';
            $env->{X_CUSTOM}    = 'custom_value';
            return $app->($env);
        }
        return $proxied->($env);
    });
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}

sub req {
    my ($path, @headers) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 5 * TIMEOUT_MULT) or return {};
    $s->autoflush(1);
    print {$s} "GET $path HTTP/1.1\r\nHost: h\r\nConnection: close\r\n",
               map({ "$_\r\n" } @headers), "\r\n";
    my $r = do { local $/; <$s> };
    close $s;
    my ($body) = ($r // '') =~ /\r\n\r\n(.*)\z/s;
    return { map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () }
             split /\n/, ($body // '') };
}

my $e = req('/api/users', 'X-Forwarded-For: 10.0.0.1');
is $e->{REMOTE_ADDR}, '10.0.0.1', 'ReverseProxy rewrote REMOTE_ADDR';

$e = req('/api/users', 'X-Forwarded-Proto: https', 'X-Forwarded-Port: 443');
is $e->{'psgi.url_scheme'}, 'https', 'ReverseProxy rewrote psgi.url_scheme';
is $e->{SERVER_PORT}, '443', 'ReverseProxy rewrote SERVER_PORT';

$e = req('/api/users', 'X-Forwarded-Host: public.example.com');
is $e->{HTTP_HOST}, 'public.example.com', 'ReverseProxy rewrote HTTP_HOST';

$e = req('/api/users');
is $e->{REMOTE_ADDR}, '127.0.0.1', 'REMOTE_ADDR untouched with nothing forwarded';

$e = req('/revise');
is_deeply [@{$e}{qw(SCRIPT_NAME X_CUSTOM PATH_INFO)}],
          ['/myapp', 'custom_value', '/revise'],
          'assigned and added env keys reach the app, PATH_INFO intact';

kill 'QUIT', $server; waitpid $server, 0;
