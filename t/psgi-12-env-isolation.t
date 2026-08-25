#!perl
# Every PSGI env value is a per-request copy: a handler's assignment neither
# leaks into a later request on the same connection nor dies with
# "Modification of a read-only value".
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

plan tests => 9;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '/';

    if ($p eq '/writable') {
        my @out;
        for my $k (qw(REQUEST_METHOD SERVER_PROTOCOL QUERY_STRING
                      REMOTE_ADDR REMOTE_PORT PATH_INFO)) {
            push @out, "$k=" . (eval { $env->{$k} = 'MUT'; 1 } ? 'rw' : 'ro');
        }
        my $b = join '|', @out;
        return [200, ['Content-Length' => length $b], [$b]];
    }
    if ($p eq '/poison') {
        # a per-request logging handle, as a logging middleware would install
        open my $fh, '>', '/dev/null' or die;
        $env->{'psgi.errors'} = $fh;
        # psgi.version was shared the same way: one assignment replaced it for
        # every later request in this worker.
        $env->{'psgi.version'} = 'POISONED';
        my $b = 'poisoned';
        return [200, ['Content-Length' => length $b], [$b]];
    }
    if ($p eq '/errors') {
        my $v = $env->{'psgi.version'};
        my $b = 'fileno=' . (fileno($env->{'psgi.errors'}) // 'undef')
              . ' ver=' . (ref $v eq 'ARRAY' ? join('.', @$v) : "BAD($v)");
        return [200, ['Content-Length' => length $b], [$b]];
    }
    # default: report REMOTE_ADDR, then rewrite it the way ReverseProxy does
    my $b = 'seen=' . $env->{REMOTE_ADDR};
    if (my $xff = $env->{HTTP_X_FORWARDED_FOR}) { $env->{REMOTE_ADDR} = $xff }
    return [200, ['Content-Length' => length $b], [$b]];
});

sub get_body {
    my ($s) = @_;
    my $buf = '';
    while (my $l = <$s>) {
        $buf .= $l;
        last if $buf =~ /\015\012\015\012/;
    }
    if ($buf =~ /Content-Length:\s*(\d+)/i && $1) { read $s, my ($b), $1; return $b }
    return '';
}

#####################################################################
# 1. Every env value a handler may reasonably assign to must be writable,
#    with and without a query string.
#####################################################################
{
    run_client("env-writable", sub {
        for my $path ('/writable?a=1', '/writable') {
            my $s = IO::Socket::INET->new(
                PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
            ) or return 10;
            $s->print("GET $path HTTP/1.1\015\012Host: l\015\012".
                      "Connection: close\015\012\015\012");
            my $b = get_body($s);
            return 11 unless $b =~ /\S/;
            # any 'ro' means a handler assignment would croak
            return 12 if $b =~ /=ro\b/;
        }
        return 0;
    });
}

#####################################################################
# 2. A REMOTE_ADDR rewrite must not survive into the next request on the
#    same keepalive connection.
#####################################################################
{
    run_client("remote-addr-no-leak", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        # request 1 carries the header the middleware trusts...
        $s->print("GET /a HTTP/1.1\015\012Host: l\015\012".
                  "X-Forwarded-For: 203.0.113.7\015\012\015\012");
        my $b1 = get_body($s);
        return 11 unless $b1 eq 'seen=127.0.0.1';
        # ...request 2 does NOT, so it must see the real peer again
        $s->print("GET /b HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $b2 = get_body($s);
        return 12 if $b2 eq 'seen=203.0.113.7';   # pre-fix
        return 13 unless $b2 eq 'seen=127.0.0.1';
        return 0;
    });
}

#####################################################################
# 3. Assigning psgi.errors must not affect any other request, even on a
#    different connection.
#####################################################################
{
    run_client("psgi-errors-not-shared", sub {
        my @seen;
        for my $path ('/errors', '/poison', '/errors') {
            my $s = IO::Socket::INET->new(
                PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
            ) or return 10;
            $s->print("GET $path HTTP/1.1\015\012Host: l\015\012".
                      "Connection: close\015\012\015\012");
            push @seen, get_body($s);
        }
        # first and last are separate connections; both must see STDERR and
        # the real psgi.version, not what the middle request assigned
        return 11 unless $seen[0] eq 'fileno=2 ver=1.1';
        return 12 unless $seen[2] eq 'fileno=2 ver=1.1';   # pre-fix: poisoned
        return 0;
    });
}

#####################################################################
# 4. Sanity: the values are still correct, not just writable.
#####################################################################
{
    run_client("env-values-correct", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("GET /x HTTP/1.1\015\012Host: l\015\012".
                  "Connection: close\015\012\015\012");
        my $b = get_body($s);
        return 11 unless $b eq 'seen=127.0.0.1';
        return 0;
    });
}
