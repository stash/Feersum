#!perl
# A PSGI status outside 100..999 answers 500 instead of unwinding out of the
# libev callback; a zero-length request body (Content-Length: 0 or an empty
# chunked body) never hands the next pipelined request to a slurping app; and
# a reader poll_cb consuming less than the buffered body keeps being called.
use strict;
use warnings;
use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;
use Feersum;
use EV;
use AnyEvent;
use IO::Socket::INET;

plan tests => 40;

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_keepalive(1);
$feer->read_timeout(3 * TMULT);

my @died;
{ no warnings 'redefine'; *Feersum::DIED = sub { push @died, $_[0] }; }

$feer->psgi_request_handler(sub {
    my $env = shift;
    my $p = $env->{PATH_INFO} || '/';

    if (my ($code) = $p =~ m{^/status/(\d+)}) {
        return [$code + 0, ['Content-Type' => 'text/plain'], ['x']];
    }
    if ($p =~ m{^/slurp}) {
        # the dangerous pattern: read far more than CONTENT_LENGTH
        my $buf = '';
        $env->{'psgi.input'}->read($buf, 65536);
        my $b = 'len=' . length($buf);
        $b .= ' LEAKED' if $buf =~ m{HTTP/1\.1} || $buf =~ /Authorization/i;
        return [200, ['Content-Length' => length $b], [$b]];
    }
    if ($p =~ m{^/chunkread}) {
        my $in  = $env->{'psgi.input'};
        my $len = $env->{CONTENT_LENGTH} || 0;
        my ($acc, $calls) = (0, 0);
        return sub {
            my $w = shift->([200, ['Content-Type' => 'text/plain']]);
            our %KEEP; $KEEP{"$w"} = $w;
            $in->poll_cb(sub {
                my $buf = '';
                $_[0]->read($buf, 1024);      # deliberately < body
                $calls++;
                $acc += length $buf;
                return if $acc < $len;
                $_[0]->poll_cb(undef);
                $w->write("done len=$acc calls=$calls");
                $w->close;
                delete $KEEP{"$w"};
            });
        };
    }
    my $b = 'ok';
    return [200, ['Content-Length' => length $b], [$b]];
});

sub talk {
    my ($bytes, $timeout) = @_;
    $timeout ||= 6 * TMULT;
    my $s = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Timeout => 5 * TMULT,
    ) or return (10, '');
    syswrite $s, $bytes;
    my $r = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        while (sysread($s, my $b, 65536)) { $r .= $b }
        alarm 0;
    };
    my $timed_out = $@ ? 1 : 0;
    close $s;
    return ($timed_out, $r);
}

#####################################################################
# 1. Out-of-range PSGI status: clean 500, worker survives.
#####################################################################
for my $code (42, 1000, 99) {
    run_client("status-$code", sub {
        my ($to, $r) = talk("GET /status/$code HTTP/1.0\015\012\015\012");
        return 11 if $to;
        return 12 unless $r =~ m{^HTTP/1\.[01] 500};
        return 0;
    });
}
# ...and the server is still there afterwards.  This has to run in the forked
# client too: a blocking read in the server's own process stops the EV loop, so
# the request would never be answered.
run_client("survives-bad-statuses", sub {
    my ($to, $r) = talk("GET /ok HTTP/1.0\015\012\015\012");
    return 11 if $to;
    return 12 unless $r =~ m{^HTTP/1\.[01] 200};
    return 0;
});

#####################################################################
# 2. Content-Length: 0 with a pipelined request behind it.
#####################################################################
run_client("zero-length-body-pipeline", sub {
    my ($to, $r) = talk(
        "POST /slurp HTTP/1.1\015\012Host: l\015\012Content-Length: 0\015\012\015\012"
      . "GET /second HTTP/1.1\015\012Host: l\015\012"
      . "Authorization: Bearer SECRET\015\012Connection: close\015\012\015\012");
    return 11 if $to;
    return 12 if $r =~ /LEAKED/;                      # got the next request
    return 13 if $r =~ /SECRET/;
    my $n = () = $r =~ m{HTTP/1\.1 200}g;
    return 14 unless $n == 2;                          # both answered
    return 0;
});

#####################################################################
# 3. Reader poll_cb must keep being called until the body is drained.
#####################################################################
run_client("pollcb-drains-body", sub {
    my $body = 'x' x 10000;
    my ($to, $r) = talk(
        "POST /chunkread HTTP/1.1\015\012Host: l\015\012"
      . "Content-Length: " . length($body) . "\015\012"
      . "Connection: close\015\012\015\012" . $body);
    return 11 if $to;                                  # pre-fix: wedged
    return 12 unless $r =~ /done len=10000 calls=(\d+)/;
    return 13 unless $1 > 1;                           # took several calls
    return 0;
});

is scalar(@died), 3, "only the three bad statuses reported through DIED";

#####################################################################
# 4. A chunked body over max_body_len is a SIZE rejection, not a
#    protocol error: the docs promise 413, and try_parse_chunked used
#    to report it through the same -1 as malformed framing (400).
#####################################################################
{
    my ($sock2, $port2) = get_listen_socket();
    my $g = Feersum->new_instance();
    $g->use_socket($sock2);
    $g->max_body_len(65536);
    $g->max_read_buf(8 * 1024 * 1024);   # so the size cap, not the buffer, trips
    $g->psgi_request_handler(sub {
        my $b = 'ok';
        return [200, ['Content-Length' => length $b], [$b]];
    });

    run_client("chunked-over-max-body-len", sub {
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port2", Timeout => 5 * TMULT,
        ) or return 10;
        $s->print("POST /big HTTP/1.1\015\012Host: l\015\012"
                . "Transfer-Encoding: chunked\015\012"
                . "Connection: close\015\012\015\012");
        my $chunk = 'z' x 16384;
        for (1 .. 16) {                       # 256 KiB > max_body_len
            $s->print(sprintf("%x\015\012", length $chunk) . $chunk . "\015\012")
                or last;
        }
        $s->print("0\015\012\015\012");
        my $r = '';
        eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 6 * TMULT;
               while (sysread($s, my $b, 65536)) { $r .= $b } alarm 0 };
        close $s;
        return 11 if $@;
        return 12 unless $r =~ m{^HTTP/1\.[01] 413};   # pre-fix: 400
        return 0;
    });
}

#####################################################################
# 5. Magic in a PSGI array body must not kill the worker (no eval frame above
#    the body writer): a tied element, a ref to a tied scalar, a tied array
#####################################################################
{
    package TiedBoom;
    sub TIESCALAR { bless {}, shift }
    sub FETCH     { die "tied scalar boom\n" }
    package TiedArrayBoom;
    sub TIEARRAY  { bless {}, shift }
    sub FETCHSIZE { 2 }
    sub FETCH     { die "tied array boom\n" }
    package TiedOK;
    sub TIESCALAR { bless {}, shift }
    sub FETCH     { 'TIED-VALUE' }
}

{
    my ($sock3, $port3) = get_listen_socket();
    my $h = Feersum->new_instance();
    $h->use_socket($sock3);
    $h->psgi_request_handler(sub {
        my $p = shift->{PATH_INFO} || '';
        if ($p =~ /elem/)   { my @a = ('x'); tie $a[1], 'TiedBoom'; return [200, [], \@a] }
        if ($p =~ /refto/)  { tie my $x, 'TiedBoom'; return [200, [], [\$x]] }
        if ($p =~ /tiedav/) { tie my @a, 'TiedArrayBoom'; return [200, [], \@a] }
        # control: magic that does NOT die must still be delivered
        my @a = ('A'); tie $a[1], 'TiedOK';
        return [200, [], \@a];
    });

    my $saved = \&Feersum::DIED;
    { no warnings 'redefine'; *Feersum::DIED = sub { } }

    # talk() above is bound to the first server's port
    my $talk3 = sub {
        my ($bytes) = @_;
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port3", Timeout => 5 * TMULT,
        ) or return (10, '');
        syswrite $s, $bytes;
        my $r = '';
        eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 6 * TMULT;
               while (sysread($s, my $b, 65536)) { $r .= $b } alarm 0 };
        my $to = $@ ? 1 : 0;
        close $s;
        return ($to, $r);
    };

    for my $case (['elem', 'tied element'], ['refto', 'ref to tied scalar'],
                  ['tiedav', 'tied array']) {
        my ($path, $desc) = @$case;
        run_client("magic-body-$path", sub {
            my ($to, $r) = $talk3->("GET /$path HTTP/1.0\015\012\015\012");
            return 11 if $to;
            return 12 unless length $r;                  # pre-fix: nothing
            return 13 unless $r =~ m{^HTTP/1\.[01] 500}; # pre-fix: worker died
            return 0;
        });
    }
    run_client("magic-body-ok-still-served", sub {
        my ($to, $r) = $talk3->("GET /okay HTTP/1.0\015\012\015\012");
        return 11 if $to;
        return 12 unless $r =~ /ATIED-VALUE/;   # working magic still delivered
        return 0;
    });
    { no warnings 'redefine'; *Feersum::DIED = $saved }
}

#####################################################################
# 6. The 2-element responder runs later, from a timer, outside any G_EVAL:
#    every croak reachable from it (bad headers, CRLF in a value, a holed
#    array) must become call_died rather than kill the worker
#####################################################################
{
    my ($sock4, $port4) = get_listen_socket();
    my $k = Feersum->new_instance();
    $k->use_socket($sock4);
    $k->psgi_request_handler(sub {
        my $p = shift->{PATH_INFO} || '';
        return sub {
            my $respond = shift;
            my $t; $t = AE::timer 0.05, 0, sub {
                undef $t;
                if    ($p =~ /odd/)   { $respond->([200, ['X-Foo']]) }
                elsif ($p =~ /notav/) { $respond->([200, 'not-an-arrayref']) }
                elsif ($p =~ /crlf/)  { $respond->([200, ['X-A' => "a\015\012X-Evil: 1"]]) }
                elsif ($p =~ /holed/) {
                    my @r; $r[1] = ['Content-Type' => 'text/plain'];
                    delete $r[0];
                    $respond->(\@r);
                }
                # Wrong arity / wrong type land in the trailing else of
                # _continue_streaming_psgi, which still croaked outright.
                elsif ($p =~ /arity1/) { $respond->([200]) }
                elsif ($p =~ /arity4/) { $respond->([200, [], [], 'extra']) }
                elsif ($p =~ /nonav/)  { $respond->({ status => 200 }) }
                else {
                    my $w = $respond->([200, ['Content-Type' => 'text/plain']]);
                    $w->write('ok'); $w->close;
                }
            };
        };
    });

    my $saved2 = \&Feersum::DIED;
    { no warnings 'redefine'; *Feersum::DIED = sub { } }

    my $ask = sub {
        my ($path) = @_;
        my $s = IO::Socket::INET->new(
            PeerAddr => "127.0.0.1:$port4", Timeout => 5 * TMULT,
        ) or return (10, '');
        syswrite $s, "GET $path HTTP/1.0\015\012\015\012";
        my $r = '';
        eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 6 * TMULT;
               while (sysread($s, my $b, 65536)) { $r .= $b } alarm 0 };
        my $to = $@ ? 1 : 0;
        close $s;
        return ($to, $r);
    };

    for my $path (qw(/odd /notav /crlf /holed /arity1 /arity4 /nonav)) {
        run_client("deferred-responder$path", sub {
            my ($to, $r) = $ask->($path);
            return 11 if $to;
            return 12 unless length $r;                  # pre-fix: no response
            return 13 unless $r =~ m{^HTTP/1\.[01] 500};
            return 14 if $r =~ /X-Evil/;                 # never inject
            return 0;
        });
    }
    # ...and the server is still alive afterwards (pre-fix /holed segfaulted)
    run_client("deferred-responder-survives", sub {
        my ($to, $r) = $ask->('/good');
        return 11 if $to;
        return 12 unless $r =~ /\015\012\015\012ok/;
        return 0;
    });
    { no warnings 'redefine'; *Feersum::DIED = $saved2 }
}
