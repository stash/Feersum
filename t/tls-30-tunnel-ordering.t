#!perl
# The TLS tunnel delivers a psgix.io stream to the app in order: a new write
# must not overtake an undrained remainder from an earlier short write.  Every
# record carries its own index - a length check alone would miss a swap.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Feersum;

my $probe = Feersum->new_instance();
plan skip_all => 'Feersum not compiled with TLS support' unless $probe->has_tls();
my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => 'no test certificates' unless -f $cert && -f $key;
eval { require IO::Socket::SSL; 1 } or plan skip_all => 'IO::Socket::SSL not installed';
plan skip_all => 'OpenSSL too old for TLS 1.3 client' unless tls_client_ok();

plan tests => 4;

my $REC     = 16;
my $RECORDS = 40000;
my $dir     = tempdir(CLEANUP => 1);
my $resfile = "$dir/result";

my ($sock, $port) = get_listen_socket();
ok $sock, 'listen socket';

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', "$dir/err";
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 0, cert_file => $cert, key_file => $key, h2 => 0) };
    my %keep;
    $f->psgi_request_handler(sub {
        my $env = shift;
        return sub {
            my $io = $env->{'psgix.io'} or return;
            my $id = 0 + $io;
            my ($buf, $next, $bad, $seen) = ('', 0, 0, 0);
            # Small sips, so the socketpair repeatedly fills and drains: that
            # is the state in which a remainder is pending while the pipe
            # still has room, which is what the direct write overtook.
            my $w;
            $w = EV::io $io, EV::READ, sub {
                my $n = sysread $io, my $z, 4096;
                return unless defined $n;
                if ($n == 0) {
                    if (open my $r, '>', $resfile) {
                        print {$r} "seen=$seen bad=$bad\n";
                        close $r;
                    }
                    undef $w;
                    delete $keep{$id};
                    return;
                }
                $buf .= $z;
                while (length($buf) >= $REC) {
                    my $rec = substr($buf, 0, $REC, '');
                    $seen++;
                    my ($idx) = $rec =~ /^(\d{10})/;
                    if (!defined $idx) { $bad++; next }
                    $bad++ if $idx != $next;
                    $next = $idx + 1;
                }
            };
            $keep{$id} = [$io, \$w];
        };
    });
    my $life_timer = EV::timer(180 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

my $s = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port",
    SSL_verify_mode => 0, Timeout => 15 * TIMEOUT_MULT);
ok $s, 'TLS client connected';

my $sent = 0;
if ($s) {
    print {$s} "GET /tunnel HTTP/1.1\r\nHost: x\r\n\r\n";
    select undef, undef, undef, 0.5 * TIMEOUT_MULT;
    eval {
        local $SIG{ALRM} = sub { die "to\n" };
        alarm 120 * TIMEOUT_MULT;
        for my $i (0 .. $RECORDS - 1) {
            my $rec = sprintf('%010d', $i) . '......';
            my $off = 0;
            while ($off < length $rec) {
                my $n = syswrite $s, substr($rec, $off);
                last if !defined $n;
                $off += $n;
            }
            $sent++;
        }
        alarm 0;
        1;
    };
    alarm 0;
    # Let the tunnel drain before tearing down, so completeness is measurable
    # and not just ordering.
    select undef, undef, undef, 4 * TIMEOUT_MULT;
    close $s;
    select undef, undef, undef, 2 * TIMEOUT_MULT;
}

my %v;
if (open my $r, '<', $resfile) {
    my $line = <$r>;
    close $r;
    chomp $line if defined $line;
    %v = map { my ($k, $x) = split /=/; ($k => $x) } split / /, ($line // q{});
}
reap_server($server);

is $v{bad} // -1, 0,
    sprintf('the tunnel never reorders: %d records read, %s out of sequence',
            $v{seen} // 0, $v{bad} // '(no report)');
is $v{seen} // -1, $sent,
    sprintf('and every record arrives (%s of %d)', $v{seen} // '(none)', $sent);
