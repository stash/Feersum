#!perl
# A tied response array or tied header list whose FETCHSIZE/FETCH dies is
# answered with a 500 rather than killing the worker, and one whose FETCHSIZE
# lies cannot make the header builder read past the end of the array.
use warnings;
use strict;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More tests => 12;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;
use EV;
use IO::Socket::INET;
use POSIX ();

{   package DyingAV;
    require Tie::Array;
    our @ISA = ('Tie::StdArray');
    sub FETCH     { die "tied FETCH exploded\n" }
    sub FETCHSIZE { die "tied FETCHSIZE exploded\n" }
}
{   package SizeLyingAV;
    require Tie::Array;
    our @ISA = ('Tie::StdArray');
    sub FETCHSIZE { 4 }          # lies: the C-level AvARRAY is empty
    sub FETCH     { 'x' }
}
{   package DieStr;              # a header object whose "" handler throws
    use overload '""' => sub { die "overload BOOM\n" }, fallback => 1;
    sub new { bless {}, shift }
}

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $evh = Feersum->new();
$evh->use_socket($socket);

my @died;
{ no warnings 'redefine'; *Feersum::DIED = sub { push @died, $_[0] }; }

$evh->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '';
    if ($p eq '/tiedtriplet') { tie my @t, 'DyingAV';     return \@t }
    if ($p eq '/tiedhdrs')    { tie my @h, 'DyingAV';     return [200, \@h, ['b']] }
    if ($p eq '/liedhdrs')    { tie my @h, 'SizeLyingAV'; return [200, \@h, ['b']] }
    # A dying "" overload on a header VALUE or NAME.  SvPV runs the overload in
    # the framing scan and in both builder passes, with no G_EVAL above them.
    if ($p eq '/ovlvalue') {
        return [200, ['Content-Type' => 'text/plain', 'X-Bad' => DieStr->new], ['b']];
    }
    if ($p eq '/ovlname') {
        return [200, [DieStr->new() => 'v'], ['b']];
    }
    # Deferred responder: same hazard on a different entry point, and this one
    # segfaulted rather than croaking (AvARRAY indexed before any FETCH).
    if ($p eq '/resptied') {
        return sub { my $w = shift; tie my @h, 'SizeLyingAV'; $w->([200, \@h]) };
    }
    return [200, ['Content-Type' => 'text/plain'], ["ok\n"]];
});

# The native (non-PSGI) entry point reaches feersum_start_response directly.
my $native_port;
{
    my ($nsock, $np) = get_listen_socket();
    $native_port = $np;
    my $nat = Feersum->new_instance();
    $nat->use_socket($nsock);
    $nat->request_handler(sub {
        my $r = shift;
        tie my @h, 'SizeLyingAV';
        $r->send_response(200, \@h, ["b"]);
    });
}

pipe(my $rpt_r, my $rpt_w) or die "pipe: $!";

# The client MUST be a separate process: this one runs the event loop, and a
# blocking read here would starve it so the server could never answer.
my $pid = fork();
die "fork: $!" unless defined $pid;

if (!$pid) {
    close $rpt_r;
    select undef, undef, undef, 0.4;
    my @out;
    for my $path (qw(/plain /tiedtriplet /tiedhdrs /liedhdrs
                     /ovlvalue /ovlname /resptied /plain)) {
        my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                      Timeout => 3 * TMULT);
        if (!$c) { push @out, 'CONNREFUSED'; next }
        syswrite $c, "GET $path HTTP/1.0\r\n\r\n";
        my $r = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 5 * TMULT;
            while (sysread($c, my $b, 4096)) { $r .= $b }
            alarm 0; 1;
        };
        close $c;
        my ($st) = $r =~ m{^HTTP/\S+ (\d+)};
        push @out, $st // (length($r) ? 'PARTIAL' : 'EMPTY');
    }
    {   # native send_response with a tied header list, on its own listener
        my $c = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$native_port",
                                      Timeout => 3 * TMULT);
        if (!$c) { push @out, 'CONNREFUSED' }
        else {
            syswrite $c, "GET /native HTTP/1.0\r\n\r\n";
            my $r = '';
            eval {
                local $SIG{ALRM} = sub { die "timeout\n" };
                alarm 5 * TMULT;
                while (sysread($c, my $b, 4096)) { $r .= $b }
                alarm 0; 1;
            };
            close $c;
            my ($st) = $r =~ m{^HTTP/\S+ (\d+)};
            push @out, $st // (length($r) ? 'PARTIAL' : 'EMPTY');
        }
    }
    syswrite $rpt_w, join(' ', @out) . "\n";
    POSIX::_exit(0);
}

close $rpt_w;

my $cv = AE::cv;
my $line = '';
my $io_w = AE::io($rpt_r, 0, sub {
    my $n = sysread($rpt_r, my $b, 256);
    if (!defined($n) || $n == 0) { $cv->send }
    else { $line .= $b; $cv->send if $line =~ /\n/ }
});
my $bail = AE::timer 60 * TMULT, 0, sub { $line ||= "BAIL"; $cv->send };
$cv->recv;
chomp $line;
waitpid $pid, 0;

my @res = split ' ', $line;

is $res[0], '200', 'baseline request works';
is $res[1], '500', 'tied response triplet answers 500, not silence';
is $res[2], '500', 'tied header list answers 500, not silence';
is $res[3], '200', 'a lying FETCHSIZE does not read past the array';
# A dying "" overload on a header: pre-fix the worker exited outright, and the
# flatten only covered a magical AV - a plain array holding an overloaded
# object is not magical.
is $res[4], '500', 'dying overload on a header value answers 500';
is $res[5], '500', 'dying overload on a header name answers 500';
# Pre-fix this was SIGSEGV: the responder indexed AvARRAY before any FETCH.
is $res[6], '200', 'tied header list through the deferred responder is safe';
# The load-bearing one: pre-fix this was CONNREFUSED - the worker was gone.
is $res[7], '200', 'server still serving after every magical shape';
# Native send_response reaches feersum_start_response directly; also SIGSEGV.
is $res[8], '200', 'tied header list through native send_response is safe';

cmp_ok scalar(@died), '>=', 2, 'Feersum::DIED was told about the tied failures';
like "@died", qr/tied FETCHSIZE exploded/, 'the DIED message names the real cause';
