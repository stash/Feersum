#!perl
# psgix.input.buffered is not advertised: Feersum's psgi.input is forward-only
# and the flag promises a seekable handle, so Plack::Request buffers the body
# itself and ->content works in any order with ->body_parameters.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use IO::Socket::INET;
use POSIX ();
use lib 't'; use Utils;
use Feersum;

# load before fork so the server child has it too
my $HAVE_PLACK_REQUEST = eval { require Plack::Request; 1 } ? 1 : 0;

plan tests => 5;

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my $BODY = 'alpha=beta&gamma=delta';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->read_timeout(15 * TIMEOUT_MULT);
    $f->header_timeout(15 * TIMEOUT_MULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $out;
        if (($env->{PATH_INFO} || q{}) eq '/plack') {
            my $req = Plack::Request->new($env);
            my $gamma = eval { $req->body_parameters->{gamma} };
            $gamma = defined $gamma ? $gamma : "ERR($@)";
            my $content = eval { $req->content };
            $content = defined $content ? $content : "ERR($@)";
            $out = "gamma=$gamma content=[$content]";
        }
        else {
            my $len = $env->{'psgi.input'}->read(my $buf, $env->{CONTENT_LENGTH});
            $out = sprintf 'flag=%s len=%d',
                exists $env->{'psgix.input.buffered'} ? 'PRESENT' : 'ABSENT',
                $len;
        }
        return [200, ['Content-Type' => 'text/plain'], [$out]];
    });
    my $life_timer = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

sub post {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 8 * TIMEOUT_MULT) or return 'CONNFAIL';
    syswrite $s, "POST $path HTTP/1.1\r\nHost: x\r\n"
        . "Content-Type: application/x-www-form-urlencoded\r\n"
        . 'Content-Length: ' . length($BODY) . "\r\nConnection: close\r\n\r\n$BODY";
    my ($buf, $g) = (q{});
    while (defined($g = sysread $s, my $z, 65536) and $g > 0) { $buf .= $z }
    close $s;
    my ($body) = $buf =~ /\r\n\r\n(.*)\z/s;
    return defined $body ? $body : 'NO-BODY';
}

my $plain = post('/flag');
like $plain, qr/flag=ABSENT/,
    'psgix.input.buffered is not advertised (the handle cannot rewind)';
like $plain, qr/len=22\b/, 'psgi.input still delivers the whole body';

SKIP: {
    skip 'Plack::Request not installed', 2 unless $HAVE_PLACK_REQUEST;
    my $got = post('/plack');
    like $got, qr/gamma=delta/, 'Plack::Request->body_parameters parses the form';
    like $got, qr/\Qcontent=[$BODY]\E/,
        'Plack::Request->content after body_parameters returns the full body';
}

reap_server($server);
