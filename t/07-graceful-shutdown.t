#!perl
use warnings;
use strict;
use constant HARDER => $ENV{RELEASE_TESTING} ? 10 : 1;
use constant CLIENTS => HARDER * 3;
use Test::More tests => 10 + 11 * CLIENTS;
use Test::Fatal;
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

    $cv->begin;
    my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain']);
    $started++;
    isa_ok($w, 'Feersum::Connection::Writer', "got a writer $cnum");
    isa_ok($w, 'Feersum::Connection::Handle', "... it's a handle $cnum");
    my $t; $t = AE::timer 1.5+rand(0.5), 0, sub {
        is exception {
            $w->write("So graceful!\n");
            $w->close();
        }, undef, "wrote after waiting a little $cnum";
        undef $t; # keep timer alive until it runs
        undef $w;
        $cv->end;
        $finished++;
    };
});

is exception {
    $evh->use_socket($socket);
}, undef, 'assigned socket';

my @got;
sub client {
    my $cnum = sprintf("%04d",shift);
    $cv->begin;
    my $h; $h = simple_client GET => '/foo',
        name => $cnum,
        timeout => 3,
        headers => {
            "Accept" => "*/*",
            'X-Client' => $cnum,
        },
    sub {
        my ($body, $headers) = @_;
        is($headers->{Status}, 200, "$cnum got 200") or diag($headers->{Reason});
        is $headers->{'transfer-encoding'}, "chunked", "$cnum got chunked!";
        is $body, "So graceful!\n", "$cnum got body";
        $cv->end;
        undef $h;
    };
}

client($_) for (1..CLIENTS);

$cv->begin;
my $death;
my $grace_t = AE::timer 1.0, 0, sub {
    pass "calling for shutdown";
    $death = AE::timer 2.5, 0, sub {
        fail "SHUTDOWN TOOK TOO LONG";
        exit 1;
    };
    $evh->graceful_shutdown(sub {
        pass "all gracefully shut down, supposedly";
        undef $death;
        $cv->end;
    });
};

$cv->begin;
my $try_connect = AE::timer 3.5, 0, sub {
    my $h; $h = AnyEvent::Handle->new(
        connect => ["localhost", $port],
        on_connect => sub {
            fail "boo, connected when shut down";
            $cv->end;
            undef $h;
        },
        on_error => sub {
            pass "cool, shouldn't be able to connect";
            $cv->end;
            undef $h;
        }
    );
};

$cv->recv;
is $started, CLIENTS, 'handlers started';
is $finished, CLIENTS, 'handlers finished';

pass "all done";
