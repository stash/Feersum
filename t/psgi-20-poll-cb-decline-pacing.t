#!perl
# A write poll_cb that declines (returns without writing) is re-invited on a
# paced backoff on every transport: neither a busy-spin on the level-triggered
# watcher nor an H2 stall until the peer happens to send a frame.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 8;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time sleep);
use Feersum;

my $probe  = Feersum->new_instance();
my $cert   = 'eg/ssl-proxy/server.crt';
my $key    = 'eg/ssl-proxy/server.key';
my $curl   = `curl --version 2>/dev/null`;
my $nghttp = `which nghttp 2>/dev/null`; chomp $nghttp;
my $tls_ok = $probe->has_tls() && -f $cert && -f $key && $curl;
my $h2_ok  = $probe->has_tls() && $probe->has_h2() && -f $cert && -f $key
          && $nghttp && -x $nghttp;

my $dir  = tempdir(CLEANUP => 1);
my $stat = "$dir/invites";
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
    $f->read_timeout(60 * TIMEOUT_MULT);
    $f->header_timeout(60 * TIMEOUT_MULT);
    eval { $f->set_tls(listener => 1, cert_file => $cert, key_file => $key,
                       $probe->has_h2 ? (h2 => 1) : ()) } if $tls_ok || $h2_ok;
    my %keep;
    my $invites = 0;
    $f->request_handler(sub {
        my $r = shift;
        my $path = $r->path;
        my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
        my $id = 0 + $w;
        $keep{$id} = $w;
        if ($path =~ m{/decline-forever}) {
            $invites = 0;    # this leg owns the counter
            $w->write('parked-');
            $w->poll_cb(sub { $invites++; return });
        }
        elsif ($path =~ m{/decline3}) {
            my $n = 0;
            $w->poll_cb(sub {
                return if ++$n <= 3;         # decline three invitations
                $_[0]->write("done after $n invites");
                $_[0]->poll_cb(undef);
                $_[0]->close;
                delete $keep{$id};
            });
        }
        elsif ($path =~ m{/external}) {
            # poll_cb always declines; the app's own timer finishes the job
            $w->poll_cb(sub { return });
            my $t; $t = EV::timer(0.05, 0, sub {
                $w->write('external event data');
                $w->poll_cb(undef);
                $w->close;
                delete $keep{$id};
                undef $t;
            });
        }
    });
    # write-then-rename so the parent never reads a half-written sample
    my $rep = EV::timer(0.1, 0.1, sub {
        open my $h, '>', "$stat.tmp" or return;
        print {$h} "$invites\n"; close $h;
        rename "$stat.tmp", $stat;
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $psock;
close $tsock;
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

sub invites {
    open my $h, '<', $stat or return -1;
    my $n = <$h> // -1; close $h; chomp $n;
    return $n;
}

sub raw_get {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$pport", Timeout => 5 * TIMEOUT_MULT) or return;
    print {$s} "GET $path HTTP/1.1\015\012Host: l\015\012"
             . "Connection: close\015\012\015\012";
    my $buf = q{};
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10 * TIMEOUT_MULT;
        while (1) {
            my $n = sysread $s, my $c, 65536;
            last if !$n;
            $buf .= $c;
        }
        alarm 0;
    };
    alarm 0;
    close $s;
    return $buf;
}

# Post-fix a 2s hold sees roughly 25 invitations (1,2,4..100ms backoff);
# pre-fix it saw around two MILLION.  Wide margins on both sides: the lower
# bound proves re-invitation continues (no silent stall), the upper proves
# the megahertz spin is gone.  Generous for slow smokers.
my $HOLD  = 2.0 * TIMEOUT_MULT;
my $UPPER = 5000;

# 1. plain: pure decliner on a live connection is paced, not spun
{
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$pport", Timeout => 5 * TIMEOUT_MULT);
    print {$s} "GET /decline-forever HTTP/1.1\015\012Host: l\015\012\015\012";
    my $got = q{};
    eval {
        local $SIG{ALRM} = sub { die "to\n" }; alarm 5 * TIMEOUT_MULT;
        while ($got !~ /parked-/) {
            my $n = sysread $s, my $c, 4096;
            last if !$n;
            $got .= $c;
        }
        alarm 0;
    };
    alarm 0;
    sleep $HOLD;
    my $n = invites();
    cmp_ok $n, '<=', $UPPER,
        "plain decline is paced, not spun ($n invitations in ${HOLD}s)";
    cmp_ok $n, '>=', 3,
        'plain decline keeps being re-invited (no silent stall)';
    close $s;
}

# 2. plain: decline-then-write completes, and promptly
{
    my $t0 = time;
    my $resp = raw_get('/decline3') // q{};
    my $dt = time - $t0;
    ok $resp =~ /done after 4 invites/
        && $resp =~ /\015\012 0 \015\012 \015\012 \z/x,
        'declining thrice then writing completes the response cleanly'
        or diag $resp;
    cmp_ok $dt, '<', 5 * TIMEOUT_MULT,
        sprintf 'and promptly (%.0f ms)', $dt * 1000;
}

# 3. plain: a write from the app's own event resumes a parked stream
{
    my $resp = raw_get('/external') // q{};
    ok $resp =~ /external event data/
        && $resp =~ /\015\012 0 \015\012 \015\012 \z/x,
        'write from an app timer resumes and completes a parked stream'
        or diag $resp;
}

# 4. TLS: same pacing bound (this path also used to spin at 100% CPU)
SKIP: {
    skip 'TLS or curl not available', 1 unless $tls_ok;
    my $max = int($HOLD + 1);
    `curl -sS -k --http1.1 --max-time $max 'https://127.0.0.1:$tport/decline-forever' 2>/dev/null`;
    my $n = invites();
    ok $n >= 3 && $n <= $UPPER,
        "TLS decline is paced, not spun ($n invitations in ~${max}s)";
}

# 5. H2: pre-fix the pump broke on the first decline and the response
# stalled until a peer frame arrived; nghttp sends none, so it hung.
SKIP: {
    skip 'H2 or nghttp not available', 1 unless $h2_ok;
    my $max = 15 * TIMEOUT_MULT;
    my $out = run_capped($max,
        ['nghttp', '--no-verify', "https://127.0.0.1:$tport/decline3"]);
    like $out, qr/done after 4 invites/,
        'H2 decline is re-invited by the paced timer instead of stalling';
}

reap_server($server);
