#!perl
# Input EOF on a parked streaming reply fires on_eof and reaps it after
# eof_park_timeout (0 disables the reap, not the signal); no EOF, no reap.
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

subtest 'setter validation' => sub {
    my $f = Feersum->new_instance;
    is $f->eof_park_timeout, 60, 'default is 60';
    $f->eof_park_timeout(2.5);
    is $f->eof_park_timeout, 2.5, 'setter round-trips';
    $f->eof_park_timeout(0);
    is $f->eof_park_timeout, 0, '0 disables';
    eval { $f->eof_park_timeout(-1) };
    like $@, qr/non-negative/, 'negative croaks';
    my $inf = 9**9**9;
    eval { $f->eof_park_timeout($inf - $inf) };
    like $@, qr/non-negative/, 'NaN croaks';
    done_testing;
};

subtest 'on_eof install dance' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    my @got;
    $f->psgi_request_handler(sub {
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            push @got, 'get-undef' unless defined $w->on_eof;
            $w->on_eof(sub { push @got, 'one' });
            ($w->on_eof)->();
            $w->on_eof(sub { push @got, 'two' });
            ($w->on_eof)->();
            $w->on_eof(undef);
            push @got, 'get-undef2' unless defined $w->on_eof;
            eval { $w->on_eof("nope") };
            push @got, 'croak' if $@;
            $w->write('x');
            $w->close;
        };
    });
    run_client 'install dance', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        print $sock "GET / HTTP/1.0\r\n\r\n";
        my $raw = '';
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        close $sock;
        return 20 unless $raw =~ m{\AHTTP/1\.0 200} && $raw =~ /x/;
        return 0;
    };
    is_deeply \@got, ['get-undef', 'one', 'two', 'get-undef2', 'croak'],
        'getter/install/replace/unset/croak';
    done_testing;
};

sub wait_for {
    my ($f, $cond, $secs) = @_;
    my $cv = AE::cv;
    my $deadline = time + $secs;
    my $wait = AE::timer(0, 0.01, sub { $cv->send if $cond->() || time >= $deadline });
    $cv->recv;
}

for my $api ('native', 'psgi') {
    subtest "fin reaps $api" => sub {
        my ($listen, $port) = get_listen_socket();
        my $f = Feersum->new_instance;
        $f->use_socket($listen);
        $f->eof_park_timeout(2);
        $f->linger_timeout(0);
        my ($eofs, $guards, %kept, $id) = (0, 0);
        my $start = sub {
            my $w = shift;
            my $i = ++$id;
            $kept{$i} = $w;
            $w->response_guard(guard { $guards++; delete $kept{$i} });
            $w->on_eof(sub { $eofs++; delete $kept{$i} });
            $w->poll_cb(sub { });
        };
        if ($api eq 'native') {
            $f->request_handler(sub { $start->(shift->start_streaming(200, ['Content-Type' => 'text/plain'])) });
        } else {
            $f->psgi_request_handler(sub { return sub { $start->(shift->([200, ['Content-Type' => 'text/plain']])) } });
        }
        run_client 'fin then server closes', sub {
            my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
                or return 10;
            my $req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            return 11 unless $sock->syswrite($req) == length $req;
            my $raw = '';
            while (index($raw, "\r\n\r\n") < 0) {
                my $n = $sock->sysread(my $part, 65536);
                return 12 unless $n;
                $raw .= $part;
            }
            return 13 unless $raw =~ m{\AHTTP/1\.1 200};
            CORE::shutdown($sock, SHUT_WR) or return 14;
            local $SIG{ALRM} = sub { die "close timeout\n" };
            alarm 10 * TMULT;
            while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
            alarm 0;
            close $sock;
            return 0;
        };
        wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
        is $f->active_conns, 0, 'conn reaped after app cleanup';
        is $eofs, 1, 'on_eof fired exactly once';
        is $guards, 1, 'response guard released';
        my $drained = 0;
        $f->graceful_shutdown(sub { $drained++ });
        is $drained, 1, 'server drains';
        done_testing;
    };
}

subtest 'quiet park without eof survives' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(1);
    $f->linger_timeout(0);
    my ($eofs, $guards, $wrote) = (0, 0, 0);
    my ($w, @timers);
    $f->psgi_request_handler(sub {
        return sub {
            $w = shift->([200, ['Content-Type' => 'text/plain']]);
            $w->response_guard(guard { $guards++ });
            $w->on_eof(sub { $eofs++ });
            $w->poll_cb(sub { });
            push @timers, AE::timer(2.5, 0, sub {
                $wrote = 1;
                $w->write('late');
                $w->close;
                undef $w;
            });
        };
    });
    run_client 'late reply with open input', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        my $req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        return 11 unless $sock->syswrite($req) == length $req;
        local $SIG{ALRM} = sub { die "reply timeout\n" };
        alarm 10 * TMULT;
        my $raw = '';
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 20 unless $raw =~ /late/;
        return 0;
    };
    wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
    ok $wrote, 'app wrote after 2.5s of quiet park';
    is $eofs, 0, 'no on_eof without input EOF';
    is $guards, 1, 'response guard released';
    is $f->active_conns, 0, 'conn closed after the late reply';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'bound reaps a neglected park' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(2);
    $f->linger_timeout(0);
    my ($eofs, $w) = (0);
    $f->psgi_request_handler(sub {
        return sub {
            $w = shift->([200, ['Content-Type' => 'text/plain']]);
            $w->on_eof(sub { $eofs++ });
            $w->poll_cb(sub { });
        };
    });
    run_client 'fin, neglected', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        my $req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        return 11 unless $sock->syswrite($req) == length $req;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        return 13 unless $raw =~ m{\AHTTP/1\.1 200};
        CORE::shutdown($sock, SHUT_WR) or return 14;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 6 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 0;
    };
    is $eofs, 1, 'on_eof fired exactly once';
    undef $w;
    wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
    is $f->active_conns, 0, 'conn freed once the app drops the writer';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'tls fin reaps' => sub {
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
            $w->on_eof(sub { $eofs++; delete $kept{$i} });
            $w->poll_cb(sub { });
        };
    });
    run_client 'tls fin then server closes', sub {
        my $sock = IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT,
            SSL_verify_mode => 0, SSL_alpn_protocols => ['http/1.1'])
            or return 10;
        my $req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        return 11 unless $sock->syswrite($req) == length $req;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        return 13 unless $raw =~ m{\AHTTP/1\.1 200};
        CORE::shutdown($sock, SHUT_WR) or return 14;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 10 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        $sock->close(SSL_no_shutdown => 1);
        return 0;
    };
    wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
    is $f->active_conns, 0, 'tls conn reaped after app cleanup';
    is $eofs, 1, 'on_eof fired exactly once';
    is $guards, 1, 'response guard released';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'bound zero still signals' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(0);
    $f->linger_timeout(0);
    my ($eofs, $guards, %kept, $id, @timers) = (0, 0);
    $f->psgi_request_handler(sub {
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            my $i = ++$id;
            $kept{$i} = $w;
            $w->response_guard(guard { $guards++; delete $kept{$i} });
            $w->on_eof(sub { $eofs++ });
            $w->poll_cb(sub { });
            push @timers, AE::timer(0.5, 0, sub { $_->close for values %kept });
        };
    });
    run_client 'fin with disabled bound', sub {
        my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
            or return 10;
        my $req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
        return 11 unless $sock->syswrite($req) == length $req;
        my $raw = '';
        while (index($raw, "\r\n\r\n") < 0) {
            my $n = $sock->sysread(my $part, 65536);
            return 12 unless $n;
            $raw .= $part;
        }
        return 13 unless $raw =~ m{\AHTTP/1\.1 200};
        CORE::shutdown($sock, SHUT_WR) or return 14;
        local $SIG{ALRM} = sub { die "close timeout\n" };
        alarm 10 * TMULT;
        while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
        alarm 0;
        close $sock;
        return 0;
    };
    wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
    is $eofs, 1, 'on_eof fires with the bound disabled';
    is $guards, 1, 'response guard released';
    is $f->active_conns, 0, 'app close still ends the response';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

subtest 'dying on_eof routes through DIED' => sub {
    my ($listen, $port) = get_listen_socket();
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->eof_park_timeout(2);
    $f->linger_timeout(0);
    my ($died_msg, $eofs, %kept, $id) = ('', 0);
    {
        no warnings 'redefine';
        local *Feersum::DIED = sub { $died_msg = $_[0] };
        $f->psgi_request_handler(sub {
            return sub {
                my $w = shift->([200, ['Content-Type' => 'text/plain']]);
                my $i = ++$id;
                $kept{$i} = $w;
                $w->response_guard(guard { delete $kept{$i} });
                $w->on_eof(sub { $eofs++; delete $kept{$i}; die "eof boom\n" });
                $w->poll_cb(sub { });
            };
        });
        run_client 'fin with dying on_eof', sub {
            my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT)
                or return 10;
            my $req = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
            return 11 unless $sock->syswrite($req) == length $req;
            my $raw = '';
            while (index($raw, "\r\n\r\n") < 0) {
                my $n = $sock->sysread(my $part, 65536);
                return 12 unless $n;
                $raw .= $part;
            }
            return 13 unless $raw =~ m{\AHTTP/1\.1 200};
            CORE::shutdown($sock, SHUT_WR) or return 14;
            local $SIG{ALRM} = sub { die "close timeout\n" };
            alarm 10 * TMULT;
            while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
            alarm 0;
            close $sock;
            return 0;
        };
        wait_for($f, sub { !$f->active_conns }, 10 * TMULT);
    }
    like $died_msg, qr/eof boom/, 'die routes through Feersum::DIED';
    is $eofs, 1, 'on_eof fired exactly once';
    is $f->active_conns, 0, 'conn reaped after the die';
    my $drained = 0;
    $f->graceful_shutdown(sub { $drained++ });
    is $drained, 1, 'server drains';
    done_testing;
};

done_testing;
