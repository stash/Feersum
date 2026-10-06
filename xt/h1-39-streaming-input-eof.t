#!perl
# Input FIN does not cancel a streaming reply whose source is not ready yet.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use IO::Socket::INET;
use Socket qw(SHUT_WR SOL_SOCKET SO_LINGER);
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
my $tls_ok = $probe->has_tls && eval { require IO::Socket::SSL; 1 } && tls_client_ok();

sub request {
    my ($path, $version, $close) = @_;
    return "GET $path HTTP/1.$version\r\nHost: x\r\n"
        . ($close ? "Connection: close\r\n" : '') . "\r\n";
}

sub response_bodies {
    my $raw = shift;
    my @bodies;
    while (length $raw) {
        my $end = index($raw, "\r\n\r\n");
        return unless $end >= 0;
        my $head = substr($raw, 0, $end + 4, '');
        return unless $head =~ m{\AHTTP/1\.[01] 200\b};
        if (my ($length) = $head =~ /^Content-Length:\s*(\d+)/mi) {
            return unless length($raw) >= $length;
            push @bodies, substr($raw, 0, $length, '');
        } elsif ($head =~ /^Transfer-Encoding:\s*chunked\r?$/mi) {
            my $body = '';
            while (1) {
                return unless $raw =~ s/\A([0-9a-fA-F]+)\r\n//;
                my $size = hex $1;
                return unless length($raw) >= $size + 2;
                $body .= substr($raw, 0, $size, '');
                return unless substr($raw, 0, 2, '') eq "\r\n";
                last if $size == 0;
            }
            push @bodies, $body;
        } else {
            push @bodies, $raw;
            $raw = '';
        }
    }
    return \@bodies;
}

my @cases = (
    ['fixed length, FIN with request', 'poll', 1, 1, 'request', 0],
    ['chunked, FIN with request', 'poll', 0, 1, 'request', 0],
    ['event-driven reply, FIN after headers', 'event', 0, 1, 'headers', 0],
    ['HTTP/1.0 close-delimited reply', 'poll', 0, 0, 'request', 0],
    ['buffered pipeline followed by FIN', 'poll', 1, 1, 'request', 1],
    ['ordinary client stays open', 'poll', 1, 1, 'none', 0],
    ['hard reset while waiting', 'poll', 1, 1, 'reset', 0],
);

for my $api ('native', 'psgi') {
    subtest $api => sub {
        for my $tls (0, 1) {
            subtest $tls ? 'TLS' : 'plain' => sub {
                plan skip_all => 'TLS client unavailable' if $tls && !$tls_ok;
                for my $case (@cases) {
                    my ($label, $source, $fixed, $version, $eof, $pipeline) = @$case;
                    subtest $label => sub {
                        my ($listen, $port) = get_listen_socket();
                        die "listen: $!" unless $listen;
                        my $f = Feersum->new_instance;
                        $f->use_socket($listen);
                        $f->set_keepalive(1);
                        $f->linger_timeout(0);
                        $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 0) if $tls;
                        my (%kept, %timers, @paths, @input);
                        my ($serial, $closed, $invites) = (0, 0, 0);
                        my $finish = sub {
                            my ($writer, $id) = @_;
                            $writer->write('done!');
                            $writer->poll_cb(undef);
                            $writer->close;
                            delete $kept{$id};
                        };
                        my $start = sub {
                            my ($writer, $path, $body) = @_;
                            my $id = ++$serial;
                            my $ready = 0;
                            $kept{$id} = $writer;
                            $writer->response_guard(guard {
                                $closed++;
                                delete $timers{$id};
                                delete $kept{$id};
                            });
                            $writer->write("start:$path:$body|");
                            $writer->poll_cb(sub {
                                $invites++;
                                return unless $ready;
                                $finish->($_[0], $id);
                            });
                            unless ($eof eq 'reset') {
                                $timers{$id} = EV::timer(0.15 * TMULT, 0, sub {
                                    delete $timers{$id};
                                    if ($source eq 'event') { $finish->($writer, $id) }
                                    else { $ready = 1 }
                                });
                            }
                        };
                        my $record = sub {
                            my $env = shift;
                            push @paths, $env->{PATH_INFO};
                            my $body = '';
                            while ($env->{'psgi.input'}->read(my $part, 4096)) { $body .= $part }
                            push @input, $body;
                            my $length = length("start:$env->{PATH_INFO}:$body|done!");
                            return ($env->{PATH_INFO}, $body, $fixed ? ['Content-Length', $length] : []);
                        };
                        if ($api eq 'native') {
                            $f->request_handler(sub {
                                my $req = shift;
                                my ($path, $body, $headers) = $record->($req->env);
                                $start->($req->start_streaming(200, $headers), $path, $body);
                            });
                        } else {
                            $f->psgi_request_handler(sub {
                                my ($path, $body, $headers) = $record->(shift);
                                return sub { $start->(shift->([200, $headers]), $path, $body) };
                            });
                        }

                        run_client 'streaming response across input closure', sub {
                            my $sock = $tls
                                ? IO::Socket::SSL->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT,
                                    SSL_verify_mode => 0, SSL_alpn_protocols => ['http/1.1'])
                                : IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 3 * TMULT);
                            return 10 unless $sock;
                            my $wire = $pipeline
                                ? "POST /first HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ndata\r\n0\r\n\r\n"
                                    . request('/second', 1, 1)
                                : request('/reply', $version, 1);
                            return 11 unless $sock->syswrite($wire) == length($wire);
                            CORE::shutdown($sock, SHUT_WR) or return 12 if $eof eq 'request';
                            my $raw = '';
                            local $SIG{ALRM} = sub { die "response timeout\n" };
                            alarm 5 * TMULT;
                            if ($eof eq 'headers' || $eof eq 'reset') {
                                while (index($raw, "\r\n\r\n") < 0) {
                                    my $n = $sock->sysread(my $part, 65536);
                                    return 13 unless $n;
                                    $raw .= $part;
                                }
                                if ($eof eq 'reset') {
                                    setsockopt($sock, SOL_SOCKET, SO_LINGER, pack('ii', 1, 0)) or return 14;
                                    $tls ? $sock->close(SSL_no_shutdown => 1) : close($sock);
                                    alarm 0;
                                    return 0;
                                }
                                CORE::shutdown($sock, SHUT_WR) or return 15;
                            }
                            while (my $n = $sock->sysread(my $part, 65536)) { $raw .= $part }
                            alarm 0;
                            $tls ? $sock->close(SSL_no_shutdown => 1) : close($sock);
                            my $bodies = response_bodies($raw) or return 16;
                            my @expected = $pipeline ? ('start:/first:data|done!', 'start:/second:|done!') : ('start:/reply:|done!');
                            return 17 unless @$bodies == @expected;
                            return 18 if grep { $bodies->[$_] ne $expected[$_] } 0 .. $#expected;
                            return 0;
                        };

                        is_deeply \@paths, $pipeline ? ['/first', '/second'] : ['/reply'], 'all complete requests reach the handler';
                        is_deeply \@input, $pipeline ? ['data', ''] : [''], 'input boundaries survive the half-close';
                        my $cv = AE::cv;
                        my $deadline = time + 1 * TMULT;
                        my $wait = AE::timer(0, 0.01, sub {
                            $cv->send if (!$f->active_conns && !keys(%kept) && !keys(%timers)) || time >= $deadline;
                        });
                        $cv->recv;
                        is $f->active_conns, 0, 'finished or reset responses release their connection';
                        is $closed, $pipeline ? 2 : 1, 'response guards release waiting work';
                        is scalar(keys %kept) + scalar(keys %timers), 0, 'no retained writer or source timer';
                        cmp_ok $invites, '>=', $eof eq 'reset' ? 1 : 2, 'the streaming source was polled';
                        my $drained = 0;
                        $f->graceful_shutdown(sub { $drained++ });
                        is $drained, 1, 'the server drains after input closure';
                        done_testing;
                    };
                }
                done_testing;
            };
        }
        done_testing;
    };
}
done_testing;
