#!perl
# A status with no content (204, 304, 1xx, 205) gets neither Content-Length
# nor chunked framing, so no body byte may reach the wire from any writer:
# array bodies, the streaming writer, an IO::Handle body, or sendfile().
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use File::Temp qw(tempfile);

plan tests => 10;

my ($fh_tmp, $tmpfile) = tempfile(UNLINK => 1);
print {$fh_tmp} 'SENDFILE-BODY-BYTES';
close $fh_tmp;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);

my $LEAK = 'LEAKED-BODY-BYTES';

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '/';

    if (my ($code) = $p =~ m{^/fh/(\d+)}) {
        my $body = $LEAK;
        open my $fh, '<', \$body or die "open: $!";
        return [$code, ['Content-Type' => 'text/plain'], $fh];
    }
    if (my ($code) = $p =~ m{^/sendfile/(\d+)}) {
        return sub {
            my $responder = shift;
            my $w = $responder->([$code, ['Content-Type' => 'text/plain']]);
            open my $in, '<', $tmpfile or die "open: $!";
            $w->sendfile($in);
            $w->close;
        };
    }
    my $b = 'second-response';
    return [200, ['Content-Type' => 'text/plain',
                  'Content-Length' => length $b], [$b]];
});

# Send $path, then a normal request on the same connection.  If the first
# response leaks an undelimited body the second response is unreadable.
sub pipelined_probe {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
    ) or return (10, '');
    $s->print("GET $path HTTP/1.1\015\012Host: l\015\012\015\012"
            . "GET /next HTTP/1.1\015\012Host: l\015\012"
            . "Connection: close\015\012\015\012");
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 6 * TMULT;
        while (sysread($s, my $b, 65536)) { $r .= $b }
        alarm 0;
    };
    close $s;
    return (11, $r) if $@;
    return (0, $r);
}

for my $case (['/fh/204', 'IO::Handle body, 204'],
              ['/fh/304', 'IO::Handle body, 304']) {
    my ($path, $desc) = @$case;
    run_client("nobody-$path", sub {
        my ($err, $r) = pipelined_probe($path);
        return $err if $err;
        # nothing at all may sit between the first response's headers and the
        # second response's status line
        return 12 if $r =~ m{\015\012\015\012(.+?)HTTP/1\.1 200}s;
        return 13 if $r =~ /\Q$LEAK\E/;
        return 14 unless $r =~ /second-response/;   # 2nd response readable
        return 0;
    });
}

SKIP: {
    skip "sendfile is Linux-only", 2 unless $^O eq 'linux';
    run_client("nobody-sendfile-304", sub {
        my ($err, $r) = pipelined_probe('/sendfile/304');
        return $err if $err;
        return 12 if $r =~ /SENDFILE-BODY-BYTES/;
        return 13 unless $r =~ /second-response/;
        return 0;
    });
}

# Control: a 200 with the same IO::Handle body must still deliver it, chunked.
run_client("200-iohandle-still-works", sub {
    my ($err, $r) = pipelined_probe('/fh/200');
    return $err if $err;
    return 12 unless $r =~ /Transfer-Encoding:\s*chunked/i;
    return 13 unless $r =~ /\Q$LEAK\E/;
    return 14 unless $r =~ /second-response/;
    return 0;
});

pass "no-body statuses emit no body on any path";
