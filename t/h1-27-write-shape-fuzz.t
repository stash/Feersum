#!perl
# Property fuzz over response write shapes: random sequences of write sizes
# including 0, 1 and multi-100 KB, across all four PSGI body forms, with and
# without a declared Content-Length, arrive byte-exact over plain, TLS and H2.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use Digest::MD5 qw(md5_hex);
use POSIX ();
use Feersum;

{
    package FuzzBody;   ## no critic (ProhibitMultiplePackages)
    sub new { my ($c, $cb) = @_; return bless { cb => $cb }, $c }
    sub getline { return $_[0]{cb}->() }
    sub close { return 1 }             ## no critic (ProhibitBuiltinHomonyms)
}

my $probe = Feersum->new_instance();
my $curl = `curl --version 2>/dev/null`;
plan skip_all => 'curl not available' unless $curl;

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
my $tls_ok = $probe->has_tls() && -f $cert && -f $key;
my $h2_ok  = $tls_ok && $probe->has_h2() && $curl =~ /\bHTTP2\b/;

# --http1.1 is curl 7.33+; older curl exits 2 on it, and it is redundant for
# plain http anyway.
my ($cmaj, $cmin) = $curl =~ m{^curl (\d+)\.(\d+)};
my $h11 = (defined $cmaj && ($cmaj > 7 || ($cmaj == 7 && $cmin >= 33))) ? q{--http1.1} : q{};

my @transports = ('plain');
push @transports, 'tls' if $tls_ok;
push @transports, 'h2'  if $h2_ok;

my $ITERS = $ENV{FEERSUM_FUZZ_ITERS} || 20;
my $seed = defined $ENV{FEERSUM_FUZZ_SEED}
    ? srand($ENV{FEERSUM_FUZZ_SEED}) : srand();

plan tests => 1 + scalar(@transports);
diag "write-shape fuzz seed $seed (set FEERSUM_FUZZ_SEED=$seed to reproduce)";

my ($psock, $pport) = get_listen_socket();
my ($tsock, $tport) = get_listen_socket();
ok $psock && $tsock, 'listen sockets';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($psock);
    $f->use_socket($tsock);
    $f->set_keepalive(1);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->header_timeout(30 * TIMEOUT_MULT);
    $f->write_timeout(30 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 1, cert_file => $cert, key_file => $key,
                       $h2_ok ? (h2 => 1) : ()) } if $tls_ok;
    my %keep;
    # The client encodes the whole write plan in headers, so every shape is
    # reproducible from the seed alone.
    $f->psgi_request_handler(sub {
        my $env   = shift;
        my @sizes = split /,/, ($env->{HTTP_X_SIZES} // q{});
        my $mode  = $env->{HTTP_X_MODE} // 'handler';
        my $total = 0;
        $total += $_ for @sizes;
        my @hdrs = ('Content-Type' => 'application/octet-stream');
        push @hdrs, ('Content-Length' => $total) if $env->{HTTP_X_CL};
        # Body byte i is chr(i % 251), so reordering or duplication shows up.
        my $pos = 0;
        my @chunks = map {
            my $n = $_;
            my $s = join q{}, map { chr(($pos + $_) % 251) } 0 .. ($n - 1);
            $pos += $n;
            $n ? $s : q{};
        } @sizes;

        return [200, \@hdrs, \@chunks] if $mode eq 'array';
        if ($mode eq 'iohandle') {
            # undef is EOF; an empty string must NOT be read as one.
            my $i = 0;
            return [200, \@hdrs,
                    FuzzBody->new(sub { $i <= $#chunks ? $chunks[ $i++ ] : undef })];
        }
        return sub {
            my $w = shift->([200, \@hdrs]);
            my $id = 0 + $w;
            if ($mode eq 'handler') {
                $w->write($_) for @chunks;
                $w->close;
                return;
            }
            my $i = 0;
            $w->poll_cb(sub {
                if ($i > $#chunks) {
                    $w->poll_cb(undef);
                    delete $keep{$id};
                    $w->close;
                    return;
                }
                $w->write($chunks[ $i++ ]);
            });
            $keep{$id} = $w;
        };
    });
    my $life_timer = EV::timer(180 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $psock;
close $tsock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

my $max = 25 * TIMEOUT_MULT;
my %bad;
for my $i (1 .. $ITERS) {
    my $n = 1 + int rand 6;
    my @sizes = map {
        my $r = rand();
          $r < 0.25 ? 0
        : $r < 0.40 ? 1
        : $r < 0.80 ? int rand 4000
        :             4096 + int rand 60_000;
    } 1 .. $n;
    my $mode  = (qw(handler pollcb iohandle array))[ int rand 4 ];
    my $cl    = (rand() < 0.5) ? 1 : 0;
    my $sizes = join q{,}, @sizes;
    my $total = 0;
    $total += $_ for @sizes;
    my $want = md5_hex(join q{}, map { chr($_ % 251) } 0 .. ($total - 1));

    for my $tr (@transports) {
        my $url = $tr eq 'plain' ? "http://127.0.0.1:$pport/f"
                                 : "https://127.0.0.1:$tport/f";
        my $proto = $tr eq 'h2' ? q{--http2} : $h11;
        my $out = `curl -sS -k $proto --max-time $max -H 'X-Sizes: $sizes' -H 'X-Mode: $mode' -H 'X-CL: $cl' '$url' 2>/dev/null`;
        my $rc = $? >> 8;
        next if $rc == 0 && md5_hex($out) eq $want;
        push @{ $bad{$tr} },
            sprintf 'i=%d mode=%s cl=%d sizes=[%s] rc=%d got=%dB want=%dB',
                $i, $mode, $cl, $sizes, $rc, length $out, $total;
    }
}

for my $tr (@transports) {
    my $n = $bad{$tr} ? scalar @{ $bad{$tr} } : 0;
    is $n, 0, "$ITERS write shapes delivered byte-exact over $tr"
        or diag join "\n", @{ $bad{$tr} }[ 0 .. ($n > 4 ? 4 : $n - 1) ];
}

reap_server($server);
