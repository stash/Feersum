#!perl
# EOF-park bound timing: a quiet park survives the early stretch, engagement
# restarts it, post-EOF retry slows to ~1s; close_notify latches it, TCP open.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;
use Socket qw(SHUT_WR);
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
my $tls_ok = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

sub wait_for {
    my ($f, $cond, $secs) = @_;
    my $cv = AE::cv;
    my $deadline = time + $secs;
    my $wait = AE::timer(0, 0.01, sub { $cv->send if $cond->() || time >= $deadline });
    $cv->recv;
}

subtest 'survives early, reaps at the bound' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(2);
    $f->linger_timeout(0);
    my ($eofs, $guards, $mid_seen, %kept, $id, @timers) = (0, 0, 0);
    $f->psgi_request_handler(sub {
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            my $i = ++$id;
            $kept{$i} = $w;
            $w->response_guard(guard { $guards++; delete $kept{$i} });
            $w->on_eof(sub { $eofs++ });
            $w->poll_cb(sub { });
            push @timers, AE::timer(1, 0, sub {
                @timers = ();
                return unless $f->active_conns;
                $mid_seen = 1;
                $w->write('mid');
            });
        };
    });
    my $t0 = time;
    run_client 'fin, mid write, then reap', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        return 11 unless $sock->syswrite("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") > 0;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        CORE::shutdown($sock, SHUT_WR) or return 13;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 12 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 20 unless $raw =~ /mid/;
        return 0;
    };
    wait_for($f, sub { !$f->active_conns }, 12 * TMULT);
    my $elapsed = time - $t0;
    ok $mid_seen, 'reply still writable 1s after FIN';
    is $eofs, 1, 'on_eof fired exactly once';
    is $guards, 1, 'response guard released';
    is $f->active_conns, 0, 'conn reaped';
    cmp_ok $elapsed, '>=', 2.5, 'reaped at the bound, not at once';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'engagement restarts the bound' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(3);   # 1s tick cadence needs > 1s slack under load
    $f->linger_timeout(0);
    my ($eofs, $guards, $ticks, $alive_at_stop, %kept, $id, @timers) = (0, 0, 0, 0);
    my $w;
    $f->psgi_request_handler(sub {
        return sub {
            $w = shift->([200, ['Content-Type' => 'text/plain']]);
            my $i = ++$id;
            $kept{$i} = $w;
            $w->response_guard(guard { $guards++; delete $kept{$i} });
            $w->on_eof(sub { $eofs++ });
            $w->poll_cb(sub { });
            push @timers, AE::timer(0, 1, sub {
                if ($ticks >= 3) {
                    $alive_at_stop = $f->active_conns;
                    @timers = ();
                    undef $w;
                    return;
                }
                $ticks++;
                $w->write("tick$ticks;");
            });
        };
    });
    run_client 'fin with engaging app', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        return 11 unless $sock->syswrite("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") > 0;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        CORE::shutdown($sock, SHUT_WR) or return 13;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 14 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 20 unless $raw =~ /tick3;/;
        return 0;
    };
    is $ticks, 3, 'three ticks written';
    is $alive_at_stop, 1, 'still alive while engaging past the bound';
    wait_for($f, sub { !$f->active_conns }, 8 * TMULT);
    is $f->active_conns, 0, 'reaped once engagement stops';
    is $eofs, 1, 'on_eof fired exactly once';
    is $guards, 1, 'response guard released';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'post-eof retry slows down' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(4);
    $f->linger_timeout(0);
    my ($eofs, $guards, $eof_at, %kept, $id, @invites) = (0, 0, 0);
    $f->psgi_request_handler(sub {
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            my $i = ++$id;
            $kept{$i} = $w;
            $w->response_guard(guard { $guards++; delete $kept{$i} });
            $w->on_eof(sub { $eofs++; $eof_at = time });
            $w->poll_cb(sub { push @invites, time });
        };
    });
    run_client 'fin with invite counting', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        return 11 unless $sock->syswrite("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") > 0;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        CORE::shutdown($sock, SHUT_WR) or return 13;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 12 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 0;
    };
    wait_for($f, sub { !$f->active_conns }, 12 * TMULT);
    my @late = grep { $_ >= $eof_at + 0.5 && $_ < $eof_at + 3.5 } @invites;
    cmp_ok scalar(@late), '<', 20, 'post-eof invites slow to ~1s cadence';
    cmp_ok scalar(@late), '>', 0, 'retries keep coming (sanity)';
    is $eofs, 1, 'on_eof fired exactly once';
    is $guards, 1, 'response guard released';
    is $f->active_conns, 0, 'conn reaped';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'close_notify latches with tcp open' => sub {
    plan skip_all => 'TLS client unavailable' unless $tls_ok;
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(2);
    $f->linger_timeout(0);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 0);
    my ($eofs, $guards, %kept, $id) = (0, 0);
    $f->psgi_request_handler(sub {
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            my $i = ++$id;
            $kept{$i} = $w;
            $w->response_guard(guard { $guards++; delete $kept{$i} });
            $w->on_eof(sub { $eofs++ });
            $w->poll_cb(sub { });
        };
    });
    run_client 'close_notify with open tcp', sub {
        my $sock = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT,
            SSL_verify_mode => 0, SSL_alpn_protocols => ['http/1.1'])
            or return 10;
        return 11 unless $sock->syswrite("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") > 0;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        return 13 unless $raw =~ m{\AHTTP/1\.1 200};
        # stop_SSL downgrades $sock in place; some versions return 1, not $sock
        $sock->stop_SSL(SSL_fast_shutdown => 0) or return 14;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 10 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 0;
    };
    wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
    is $f->active_conns, 0, 'conn reaped within the bound';
    is $eofs, 1, 'on_eof fired exactly once';
    is $guards, 1, 'response guard released';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

done_testing;
