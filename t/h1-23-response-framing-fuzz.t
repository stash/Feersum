#!perl
# Property fuzz over the response space (status x header count x array vs
# streaming body x chunk sizes x GET/HEAD) on a keepalive connection: the body
# the client reassembles is exactly what the handler supplied, a no-body status
# carries none, and a second request on the same socket is still answered.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 5;
use IO::Socket::INET;
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

my $ITERS = $ENV{FEERSUM_FUZZ_ITERS} || 120;

# Statuses that must be sent without a message body whatever the handler
# supplies (RFC 9110); 205 is included per RFC 7231 6.3.6.
my %NO_BODY = map { $_ => 1 } (204, 205, 304);
my @STATUS  = (200, 201, 202, 204, 205, 206, 300, 304, 400, 404, 500, 503);
my @MODES   = qw(array stream);

my ($sock, $port) = get_listen_socket();
ok $sock, "got listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    my $f = Feersum->new();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->read_timeout(20 * TIMEOUT_MULT);
    $f->write_timeout(20 * TIMEOUT_MULT);
    $f->header_timeout(20 * TIMEOUT_MULT);
    our @keep;
    # The client encodes the response it wants in request headers, so every
    # shape is reproducible from the seed alone.
    $f->psgi_request_handler(sub {
        my $env = shift;
        my $status = $env->{HTTP_X_STATUS} || 200;
        my $nh     = $env->{HTTP_X_NHDRS}  || 0;
        my $mode   = $env->{HTTP_X_MODE}   || 'array';
        my @body   = map { 'x' x $_ } grep { length }
                     split /,/, ($env->{HTTP_X_CHUNKS} // q{});
        my @hdrs   = ('Content-Type' => 'text/plain');
        push @hdrs, ("X-Pad-$_" => ('p' x (($_ * 7) % 40 + 1))) for 1 .. $nh;
        if ($mode eq 'stream') {
            return sub {
                my $respond = shift;
                my $w = $respond->([$status, \@hdrs]);
                push @keep, $w;
                $w->write($_) for @body;
                $w->close;
            };
        }
        return [$status, \@hdrs, \@body];
    });
    my $life_timer = EV::timer(90 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;

# Read exactly one response, honouring CL / chunked / no-body rules.  Leftover
# bytes stay in $$bufref so a misframed response shows up as a desync below.
sub read_one {
    my ($s, $bufref, $bodiless) = @_;
    my $deadline = time + 15 * TIMEOUT_MULT;
    my $fill = sub {
        return 0 if time > $deadline;
        my $g = sysread $s, my $z, 65536;
        return 0 if !defined $g || $g == 0;
        $$bufref .= $z;
        return 1;
    };
    until ($$bufref =~ /\r\n\r\n/) { $fill->() or return }
    my ($head, $rest) = split /\r\n\r\n/, $$bufref, 2;
    my @lines = split /\r\n/, $head;
    my $sl = shift @lines;
    my ($status) = $sl =~ m{^HTTP/1\.\d\ (\d{3})}x or return;
    my %h;
    for my $l (@lines) {
        my ($k, $v) = $l =~ /^([^:]+):\s*(.*)$/ or next;
        push @{ $h{lc $k} }, $v;
    }
    if ($bodiless) { $$bufref = $rest; return ($status, \%h, q{}) }

    if (exists $h{'content-length'}) {
        my $cl = $h{'content-length'}[0];
        until (length($rest) >= $cl) {
            $$bufref = $rest; $fill->() or return; $rest = $$bufref;
        }
        my $body = substr $rest, 0, $cl, q{};
        $$bufref = $rest;
        return ($status, \%h, $body);
    }
    if ((($h{'transfer-encoding'} || [q{}])->[0]) =~ /chunked/i) {
        my $body = q{};
        while (1) {
            until ($rest =~ /\r\n/) { $$bufref = $rest; $fill->() or return; $rest = $$bufref }
            my ($szline, $tail) = split /\r\n/, $rest, 2;
            my ($sz) = $szline =~ /^([0-9a-fA-F]+)/ or return;
            $sz = hex $sz;
            if ($sz == 0) {
                until ($tail =~ /\r\n/) { $$bufref = $tail; $fill->() or return; $tail = $$bufref }
                $tail =~ s/^\r\n//;
                $$bufref = $tail;
                return ($status, \%h, $body);
            }
            until (length($tail) >= $sz + 2) { $$bufref = $tail; $fill->() or return; $tail = $$bufref }
            $body .= substr $tail, 0, $sz, q{};
            $tail =~ s/^\r\n//;
            $rest = $tail;
        }
    }
    return ($status, \%h, undef);   # close-delimited
}

my (@framing, @desync, @statuses, @nobody);
# Every read is bounded by SO_RCVTIMEO, but $ITERS of them are not: once the
# server stops answering, grinding through the rest at the per-read timeout
# takes tens of minutes and reads as a hung run rather than a failed one.
# Give up early and report, which is what a wedged server deserves.
my $consecutive_dead = 0;
my $bailed;
for my $i (1 .. $ITERS) {
    if ($consecutive_dead >= 5) { $bailed = $i; last }
    my $status = $STATUS[ rand @STATUS ];
    my $mode   = $MODES[ rand @MODES ];
    my $nh     = int rand 4;
    my @lens   = map { int rand 60 } 1 .. int(rand 4);
    my $chunks = join q{,}, @lens;
    my $want   = 0; $want += $_ for @lens;
    my $head   = (rand() < 0.25) ? 1 : 0;
    my $meth   = $head ? 'HEAD' : 'GET';
    my $desc   = "i=$i status=$status mode=$mode nh=$nh chunks=[$chunks] $meth";
    my $bodiless = $head || $NO_BODY{$status} || $status < 200;

    rcv_timeout(my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
                                  Timeout => 10 * TIMEOUT_MULT), 15 * TIMEOUT_MULT)
        or do { push @framing, "$desc: connect failed"; $consecutive_dead++; next };
    syswrite $s, "$meth /r HTTP/1.1\r\nHost: x\r\nX-Status: $status\r\n"
               . "X-Nhdrs: $nh\r\nX-Chunks: $chunks\r\nX-Mode: $mode\r\n\r\n";
    my $buf = q{};
    my ($st, $h, $body) = read_one($s, \$buf, $bodiless);
    if (!defined $st) {
        push @framing, "$desc: no parseable response";
        $consecutive_dead++;
        close $s;
        next;
    }
    $consecutive_dead = 0;

    push @statuses, "$desc: got status $st" if $st != $status;
    if ($bodiless) {
        push @nobody, "$desc: sent " . length($body) . ' body bytes'
            if defined $body && length $body;
    }
    elsif (defined $body && $body ne 'x' x $want) {
        push @framing, sprintf '%s: body %d bytes, wanted %d', $desc, length($body), $want;
    }
    push @framing, "$desc: duplicate Content-Length"
        if $h->{'content-length'} && @{ $h->{'content-length'} } > 1;
    push @framing, "$desc: both Content-Length and Transfer-Encoding"
        if $h->{'content-length'} && $h->{'transfer-encoding'};

    # Reuse the connection: a misframed response shows up here as a wrong or
    # missing second reply.
    if (!$h->{connection} || $h->{connection}[0] !~ /close/i) {
        syswrite $s, "GET /r HTTP/1.1\r\nHost: x\r\nX-Status: 299\r\nX-Nhdrs: 0\r\n"
                   . "X-Chunks: 11\r\nX-Mode: array\r\n\r\n";
        my ($st2, undef, $body2) = read_one($s, \$buf, 0);
        if    (!defined $st2)  { push @desync, "$desc: no second response" }
        elsif ($st2 != 299)    { push @desync, "$desc: second status $st2" }
        elsif (($body2 // q{}) ne 'x' x 11) {
            push @desync, sprintf '%s: second body %d bytes', $desc,
                          length($body2 // q{});
        }
    }
    close $s;
}

reap_server($server);

diag "bailed out at iteration $bailed of $ITERS: the server stopped answering"
    if $bailed;

is scalar(@statuses), 0, "$ITERS shapes: status line always matches"
    or diag join "\n", @statuses[0 .. ($#statuses > 4 ? 4 : $#statuses)];
is scalar(@framing), 0, "$ITERS shapes: response framing always correct"
    or diag join "\n", @framing[0 .. ($#framing > 4 ? 4 : $#framing)];
is scalar(@nobody), 0, '1xx/204/205/304/HEAD never carry a body'
    or diag join "\n", @nobody[0 .. ($#nobody > 4 ? 4 : $#nobody)];
is scalar(@desync), 0, 'keepalive connection never desynchronises'
    or diag join "\n", @desync[0 .. ($#desync > 4 ? 4 : $#desync)];
