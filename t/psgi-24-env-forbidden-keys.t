#!perl
# PSGI 1.1: "The environment MUST NOT contain keys named HTTP_CONTENT_TYPE or
# HTTP_CONTENT_LENGTH."  Feersum special-cases the dashed spellings, but header
# names are normalised with '-' and '_' both mapping to '_', so a client sending
# "Content_Length:" reached the ordinary HTTP_ path and injected one.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More tests => 7;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();

my $CRLF = "\015\012";

my ($lsn, $port) = get_listen_socket();
ok $lsn, 'made listen socket';

my $spid = fork();
die "fork: $!" unless defined $spid;
if ($spid == 0) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    $SIG{QUIT} = 'DEFAULT';
    require Feersum;
    my $f = Feersum->new_instance();
    $f->use_socket($lsn);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my @k = grep {
            /^(?:HTTP_CONTENT_(?:LENGTH|TYPE)|CONTENT_LENGTH|CONTENT_TYPE)$/
        } sort keys %$env;
        return [200, ['Content-Type' => 'text/plain'],
                [join(';', map { "$_=$env->{$_}" } @k)]];
    });
    EV::run();
    POSIX::_exit(0);
}
close $lsn;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

sub body_for {
    my ($req) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
        Proto => 'tcp', Timeout => 5 * TIMEOUT_MULT) or return '';
    $s->autoflush(1);
    syswrite $s, $req;
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5 * TIMEOUT_MULT;
        while (1) { my $n = sysread($s, my $b, 4096); last if !defined $n || $n == 0; $r .= $b }
        alarm 0; 1;
    } or do { alarm 0 };
    close $s;
    my ($body) = $r =~ /\r\n\r\n(.*)/s;
    return $body // '';
}

my $b = body_for(
    "POST / HTTP/1.1${CRLF}Host: x${CRLF}Content_Length: 9${CRLF}"
  . "Content-Length: 5${CRLF}Connection: close${CRLF}${CRLF}hello");
unlike $b, qr/HTTP_CONTENT_LENGTH/, 'Content_Length: does not inject HTTP_CONTENT_LENGTH';
like   $b, qr/\bCONTENT_LENGTH=5\b/, 'the real CONTENT_LENGTH is unaffected';

$b = body_for(
    "POST / HTTP/1.1${CRLF}Host: x${CRLF}Content_Type: text/x-evil${CRLF}"
  . "Content-Type: text/plain${CRLF}Content-Length: 5${CRLF}"
  . "Connection: close${CRLF}${CRLF}hello");
unlike $b, qr/HTTP_CONTENT_TYPE/, 'Content_Type: does not inject HTTP_CONTENT_TYPE';
like   $b, qr{\bCONTENT_TYPE=text/plain}, 'the real CONTENT_TYPE is unaffected';

# The ordinary spellings must keep working exactly as before.
$b = body_for(
    "POST / HTTP/1.1${CRLF}Host: x${CRLF}Content-Type: text/plain${CRLF}"
  . "Content-Length: 5${CRLF}Connection: close${CRLF}${CRLF}hello");
like $b, qr{\bCONTENT_TYPE=text/plain}, 'dashed Content-Type still becomes CONTENT_TYPE';
like $b, qr/\bCONTENT_LENGTH=5\b/,      'dashed Content-Length still becomes CONTENT_LENGTH';

kill 'QUIT', $spid; kill 'TERM', $spid;
waitpid $spid, 0;
