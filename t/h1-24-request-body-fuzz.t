#!perl
# Request-body fuzz: framing x size x TCP segmentation x how much of psgi.input
# the app reads.  The bytes the app reads are exactly the bytes sent, and the
# connection stays framed afterwards whatever the app left unread.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 5;
use IO::Socket::INET;
use Digest::MD5 qw(md5_hex);
use POSIX ();
use lib 't'; use Utils;
use Feersum;
use Socket ();

# sysread on a blocking socket waits forever regardless of any deadline the
# caller is tracking, so a server that stops answering wedges the whole run
# instead of failing.  Bound every read at the socket.
sub rcv_timeout {
    my ($sock, $secs) = @_;
    return $sock unless $sock;
    setsockopt $sock, Socket::SOL_SOCKET(), Socket::SO_RCVTIMEO(),
        pack('l!l!', $secs, 0);
    return $sock;
}

my $seed = defined $ENV{FEERSUM_FUZZ_SEED}
    ? srand($ENV{FEERSUM_FUZZ_SEED}) : srand();
diag("fuzz seed $seed (set FEERSUM_FUZZ_SEED=$seed to reproduce)");
my $ITERS = $ENV{FEERSUM_FUZZ_ITERS} || 80;

my ($sock, $port) = get_listen_socket();
ok $sock, "got listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->max_body_len(8 * 1024 * 1024);
    $f->read_timeout(20 * TIMEOUT_MULT);
    $f->write_timeout(20 * TIMEOUT_MULT);
    $f->header_timeout(20 * TIMEOUT_MULT);
    # Echo a digest of exactly what was read, so the client can prove identity.
    # Note the fresh lexical per iteration: Feersum's read() APPENDS to the
    # buffer rather than replacing it (see the psgi.input POD).
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $mode = $env->{HTTP_X_READ} // 'all';
        my $in   = $env->{'psgi.input'};
        my ($data, $n) = (q{}, 0);
        if ($mode eq 'all' && $in) {
            while (my $g = $in->read(my $chunk, 65536)) { $data .= $chunk; $n += $g }
        }
        elsif ($mode eq 'partial' && $in) {
            my $g = $in->read(my $chunk, 17);
            if ($g) { $data = $chunk; $n = $g }
        }
        # mode 'none': psgi.input is never touched
        my $body = join q{|}, "n=$n", 'md5=' . md5_hex($data),
                   'cl=' . (defined $env->{CONTENT_LENGTH} ? $env->{CONTENT_LENGTH} : 'undef');
        return [200, ['Content-Type' => 'text/plain'], [$body]];
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

sub read_resp {
    my ($s, $bufref) = @_;
    my $deadline = time + 20 * TIMEOUT_MULT;
    my $fill = sub {
        return 0 if time > $deadline;
        my $g = sysread $s, my $z, 65536;
        return 0 if !defined $g || $g == 0;
        $$bufref .= $z;
        return 1;
    };
    until ($$bufref =~ /\r\n\r\n/) { $fill->() or return }
    my ($head, $rest) = split /\r\n\r\n/, $$bufref, 2;
    my ($status) = $head =~ m{^HTTP/1\.\d\ (\d{3})}x or return;
    my ($cl) = $head =~ /^Content-Length:\s*(\d+)/mi;
    $cl = 0 unless defined $cl;
    until (length($rest) >= $cl) { $$bufref = $rest; $fill->() or return; $rest = $$bufref }
    my $body = substr $rest, 0, $cl, q{};
    $$bufref = $rest;
    return ($status, $body);
}

sub chunkify {
    my ($data, $nchunks) = @_;
    my ($out, $len, $off) = (q{}, length $data, 0);
    my $per = int($len / ($nchunks || 1)) + 1;
    while ($off < $len) {
        my $take = ($len - $off < $per) ? $len - $off : $per;
        $out .= sprintf('%x', $take) . "\r\n" . substr($data, $off, $take) . "\r\n";
        $off += $take;
    }
    return $out . "0\r\n\r\n";
}

my (@integrity, @clen, @desync);
for my $i (1 .. $ITERS) {
    my $mode  = (qw(all partial none))[ rand 3 ];
    my $frame = (qw(cl chunked))[ rand 2 ];
    my $size  = (rand() < 0.35) ? int rand 40 : int rand 150_000;
    my $data  = join q{}, map { chr(65 + int rand 26) } 1 .. $size;
    my $desc  = "i=$i mode=$mode frame=$frame size=$size";

    my $req = $frame eq 'cl'
        ? "POST /b HTTP/1.1\r\nHost: x\r\nX-Read: $mode\r\nContent-Length: $size\r\n\r\n$data"
        : "POST /b HTTP/1.1\r\nHost: x\r\nX-Read: $mode\r\n"
          . "Transfer-Encoding: chunked\r\n\r\n" . chunkify($data, 1 + int rand 6);

    rcv_timeout(my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 10 * TIMEOUT_MULT), 15 * TIMEOUT_MULT)
        or do { push @integrity, "$desc: connect failed"; next };
    # Split across TCP segments at random offsets: headers and body both have
    # to survive reassembly across reads.
    my ($off, $total) = (0, length $req);
    while ($off < $total) {
        my $take = 1 + int rand 40_000;
        $take = $total - $off if $off + $take > $total;
        my $w = syswrite $s, substr($req, $off, $take);
        last if !defined $w;
        $off += $w;
    }

    my $buf = q{};
    my ($st, $body) = read_resp($s, \$buf);
    if (!defined $st || $st != 200) {
        push @integrity, "$desc: status " . (defined $st ? $st : 'none');
        close $s;
        next;
    }
    my %got = map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } split /\|/, $body;

    if ($mode eq 'all') {
        push @integrity, "$desc: app read $got{n} bytes, sent $size"
            if ($got{n} // -1) != $size;
        push @integrity, "$desc: body content differs (md5)"
            if ($got{md5} // q{}) ne md5_hex($data);
    }
    elsif ($mode eq 'partial') {
        my $want = $size < 17 ? $size : 17;
        push @integrity, "$desc: short read got $got{n}, wanted $want"
            if ($got{n} // -1) != $want;
        push @integrity, "$desc: short-read content differs (md5)"
            if ($got{md5} // q{}) ne md5_hex(substr $data, 0, $want);
    }
    push @clen, "$desc: CONTENT_LENGTH=$got{cl}, sent $size"
        if $frame eq 'cl' && ($got{cl} // q{}) ne "$size";

    syswrite $s, "POST /b HTTP/1.1\r\nHost: x\r\nX-Read: all\r\n"
               . "Content-Length: 5\r\n\r\nHELLO";
    my ($st2, $body2) = read_resp($s, \$buf);
    if (!defined $st2)  { push @desync, "$desc: no second response" }
    elsif ($st2 != 200) { push @desync, "$desc: second status $st2" }
    else {
        my %g2 = map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } split /\|/, $body2;
        push @desync, "$desc: second body wrong (n=$g2{n})"
            if ($g2{n} // -1) != 5 || ($g2{md5} // q{}) ne md5_hex('HELLO');
    }
    close $s;
}

reap_server($server);

is scalar(@integrity), 0, "$ITERS shapes: app receives exactly the bytes sent"
    or diag join "\n", @integrity[0 .. ($#integrity > 4 ? 4 : $#integrity)];
is scalar(@clen), 0, 'CONTENT_LENGTH always matches the body sent'
    or diag join "\n", @clen[0 .. ($#clen > 4 ? 4 : $#clen)];
is scalar(@desync), 0,
    'connection stays framed even when the app reads none or part of the body'
    or diag join "\n", @desync[0 .. ($#desync > 4 ? 4 : $#desync)];
pass 'request-body property sweep complete';
