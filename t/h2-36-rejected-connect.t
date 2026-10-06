#!perl
# A rejected Extended CONNECT is an ordinary HTTP response. Closing its PSGI
# writer or reaching IO-body EOF must finish the stream without a tunnel relay.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils; use H2Utils;
use Feersum;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(time);

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my $probe = Feersum->new_instance;
plan skip_all => 'TLS/H2 unavailable' unless $probe->has_tls && $probe->has_h2 && tls_client_ok();
my $dir = tempdir(CLEANUP => 1);
my ($listen, $port) = get_listen_socket();
my $pid = fork;
die "fork: $!" unless defined $pid;
if (!$pid) {
    $SIG{QUIT} = 'DEFAULT';
    open STDERR, '>', "$dir/server.log" or die $!;
    my $f = Feersum->new_instance;
    $f->use_socket($listen);
    $f->set_tls(cert_file => 't/certs/alpha.crt', key_file => 't/certs/alpha.key', h2 => 1);
    $f->read_timeout(30 * TMULT);
    $f->write_timeout(30 * TMULT);
    $f->psgi_request_handler(sub {
        my $env = shift;
        return [200, ['Content-Type' => 'text/plain'], ['probe']] if $env->{PATH_INFO} eq '/probe';
        if ($env->{PATH_INFO} eq '/io') {
            open my $body, '<', \"Forbidden" or die $!;
            return [403, ['Content-Type' => 'text/plain'], $body];
        }
        return [403, ['Content-Type' => 'text/plain'], ['Forbidden']] if $env->{PATH_INFO} eq '/array';
        return sub {
            my $w = shift->([403, ['Content-Type' => 'text/plain']]);
            $w->write('For');
            $w->write('bidden');
            $w->close;
        };
    });
    my $report = EV::timer(0, 0.02, sub {
        open my $out, '>', "$dir/stats.tmp" or die $!;
        print {$out} $f->active_conns, "\n";
        close $out;
        rename "$dir/stats.tmp", "$dir/stats" or die $!;
    });
    my $life = EV::timer(90 * TMULT, 0, sub { POSIX::_exit(0) });
    EV::run;
    POSIX::_exit(0);
}
my $cleanup = guard { reap_server($pid) };
close $listen;

for my $case (map { [$_, 0], [$_, 1] } ('array', 'writer', 'io')) {
    my ($body, $input_closed) = @$case;
    subtest "$body rejection with input " . ($input_closed ? 'closed' : 'open') => sub {
        my $s = h2_connect($port) or die 'H2 connect failed';
        my $flags = FLAG_END_HEADERS | ($input_closed ? FLAG_END_STREAM : 0);
        $s->syswrite(h2_frame(H2_HEADERS, $flags, 1,
            hpack_encode_headers([':method', 'CONNECT'], [':protocol', 'websocket'],
                                 [':scheme', 'https'], [':authority', 'x'], [':path', "/$body"])));
        my ($status, $content, $ended, $reset) = (undef, '', 0, 0);
        my $deadline = time + 1.5 * TMULT;
        while (time < $deadline) {
            my $fr = h2_read_frame($s, 0.1) or next;
            next unless $fr->{stream_id} == 1;
            $status = hpack_decode_status($fr->{payload}) if $fr->{type} == H2_HEADERS;
            $content .= $fr->{payload} if $fr->{type} == H2_DATA;
            $reset = 1 if $fr->{type} == H2_RST_STREAM;
            if (($fr->{type} == H2_HEADERS || $fr->{type} == H2_DATA)
                && ($fr->{flags} & FLAG_END_STREAM)) { $ended = 1; last }
        }
        is $status, 403, 'the application rejects the upgrade';
        is $content, 'Forbidden', 'the error body is delivered';
        ok $ended, 'the response ends without waiting for write_timeout';
        ok !$reset, 'rejection finishes normally without resetting the stream';

        # A browser normally leaves CONNECT input open until it sees rejection.
        $s->syswrite(h2_frame(H2_DATA, FLAG_END_STREAM, 1, '')) unless $input_closed;

        my $active;
        $deadline = time + 0.5 * TMULT;
        while (time < $deadline) {
            if (open my $in, '<', "$dir/stats") {
                chomp($active = <$in> // 'missing');
                close $in;
                last if $active eq '1';
            }
            select undef, undef, undef, 0.02;
        }
        is $active, 1, 'only the reusable transport remains after rejection';
        $s->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM, 3,
            hpack_encode_headers([':method', 'GET'], [':scheme', 'https'],
                                 [':authority', 'x'], [':path', '/probe'])));
        my $next = h2_read_until($s, H2_HEADERS, 3, 2 * TMULT);
        is $next ? hpack_decode_status($next->{payload}) : 'no response', 200,
            'the connection continues serving ordinary requests';
        $s->close;
    };
}
done_testing;
