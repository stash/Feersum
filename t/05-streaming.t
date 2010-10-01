#!perl
use warnings;
use strict;
use constant CLIENTS_11 => 15;
use constant CLIENTS_10 => 15;
use constant CLIENTS => CLIENTS_11 + CLIENTS_10;
use Test::More tests => 7 + 21 * CLIENTS_11 + 22 * CLIENTS_10;
use Test::Exception;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        fail "Died during request handler: $err";
    };
}

my $cv = AE::cv;
my $started = 0;
my $finished = 0;
$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';
    my $env = $r->env();
    ok $env && ref($env) eq 'HASH';

    ok $env->{'psgi.streaming'}, 'got psgi.streaming';
    my $cnum = $env->{HTTP_X_CLIENT};
    ok $cnum, "got client number";

    ok !$r->can('write'), "write method removed from connection object";

    $cv->begin;
    my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain', 'X-Client' => $cnum]);
    $started++;
    isa_ok($w, 'Feersum::Connection::Writer', "got a writer $cnum");
    isa_ok($w, 'Feersum::Connection::Handle', "... it's a handle $cnum");
    my $n = 0;
    my $t; $t = AE::timer rand(),rand(), sub {
        $n++;
        eval {
            ok blessed($w), "still blessed? $cnum";
            if ($n == 1) {
                # cover PADTMP case
                $w->write("$cnum Hello streaming world! chunk ".
                          ($n==1?"one":"WTF")."\n");
                pass "wrote chunk $n $cnum";
            }
            elsif ($n == 2) {
                # cover PADMY case
                my $d = "$cnum Hello streaming world! chunk ".
                        ($n==1?"WTF":"'two'")."\n";
                $w->write($d);
                pass "wrote chunk $n $cnum";
            }
            elsif ($n == 3) {
                my $buf = "$cnum Hello streaming world! chunk three\n";
                $w->poll_cb(sub {
                    my $w2 = shift;
                    isa_ok($w2, 'Feersum::Connection::Writer',
                        "got another writer $cnum");
                    $w2->write($buf);
                    $w2->poll_cb(undef); # unset
                });
            }
            else {
                $w->close();
                pass "async writer finished $cnum";
                dies_ok {
                    $w->write("after completion");
                } "can't write after completion $cnum";
                $finished++;
                $cv->end;
                undef $t; # important ref
            }
        }; if ($@) {
            warn "oshit $cnum $@";
        }
    };
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

sub client {
    my $cnum = sprintf("%04d",shift);
    my $is_chunked = shift || 0;
    $cv->begin;
    my $h; $h = simple_client GET => '/foo',
        name => $cnum,
        timeout => 15,
        proto => $is_chunked ? '1.1' : '1.0',
        headers => {
            "Accept" => "*/*",
            'X-Client' => $cnum,
        },
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 200, "$cnum got 200"
            or diag $headers->{Reason};
        if ($is_chunked) {
            is $headers->{HTTPVersion}, '1.1';
            is $headers->{'transfer-encoding'}, "chunked", "$cnum got chunked!";
        }
        else {
            is $headers->{HTTPVersion}, '1.0';
            ok !exists $headers->{'transfer-encoding'}, "$cnum not chunked!";
            is $headers->{'connection'}, 'close', "$cnum conn closed";
        }
        is_deeply [split /\n/,$body], [
            "$cnum Hello streaming world! chunk one",
            "$cnum Hello streaming world! chunk 'two'",
            "$cnum Hello streaming world! chunk three",
        ], "$cnum got all three lines";
        $cv->end;
        undef $h;
    };
}


client(1000+$_,1) for (1..CLIENTS_11);
client(2000+$_,0) for (1..CLIENTS_10); # HTTP/1.0 style

$cv->recv;
is $started, CLIENTS, 'handlers started';
is $finished, CLIENTS, 'handlers finished';

pass "all done";
