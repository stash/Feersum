#!perl
# The native send_response() rejects a bad body type and a non-numeric status
# before any header bytes are queued, so the client gets a 500 rather than a
# truncated header block that swallows the next keepalive response.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;

plan tests => 12;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

my @died;
{ no warnings 'redefine'; *Feersum::DIED = sub { push @died, $_[0] }; }

my $SECRET = 'SECRET-SECOND-RESPONSE';

$feer->request_handler(sub {
    my $r = shift;
    my $p = $r->path || '/';
    return $r->send_response(200, ['Content-Type' => 'text/plain'], {oops => 1})
        if $p eq '/hashref';
    return $r->send_response(200, ['Content-Type' => 'text/plain'], sub { 1 })
        if $p eq '/coderef';
    return $r->send_response('banana', ['Content-Type' => 'text/plain'], \'x')
        if $p eq '/badstatus';
    return $r->send_response(-5, ['Content-Type' => 'text/plain'], \'x')
        if $p eq '/negstatus';
    return $r->send_response(99, ['Content-Type' => 'text/plain'], \'x')
        if $p eq '/shortstatus';
    return $r->send_response(200,
        ['Content-Type' => 'text/plain', 'Content-Length' => length $SECRET],
        \$SECRET);
});

sub pipelined {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
    ) or return (10, '');
    $s->print("GET $path HTTP/1.1\015\012Host: l\015\012\015\012"
            . "GET /ok HTTP/1.1\015\012Host: l\015\012"
            . "Connection: close\015\012\015\012");
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 6 * TMULT;
        while (sysread($s, my $b, 65536)) { $r .= $b }
        alarm 0;
    };
    close $s;
    return ($@ ? 11 : 0, $r);
}

# Each bad response must be a self-contained 500, and must never let the
# following response's body be delivered as this one's.
for my $case (['/hashref',     'hashref body'],
              ['/coderef',     'coderef body'],
              ['/badstatus',   'non-numeric status'],
              ['/negstatus',   'negative status'],
              ['/shortstatus', 'two-digit status']) {
    my ($path, $desc) = @$case;
    run_client("native-$desc", sub {
        my ($err, $r) = pipelined($path);
        return $err if $err;
        return 12 unless length $r;                    # pre-fix: 0 bytes
        return 13 unless $r =~ m{^HTTP/1\.[01] 500};   # must answer 500
        return 14 if $r =~ /\Q$SECRET\E/;              # pre-fix: absorbed
        return 0;
    });
}

is scalar(@died), 5, "each bad response reported through Feersum::DIED";
