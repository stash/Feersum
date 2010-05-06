#!perl
use warnings;
use strict;
use constant CLIENTS => 12;
use Test::More tests => 10 + 8 * CLIENTS;
use Test::Exception;
use Test::Differences;
use blib;
use Carp ();
use Encode;
use utf8;
use bytes; no bytes;
use Scalar::Util qw/blessed/;
$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

BEGIN { use_ok('Feersum') };

use IO::Socket::INET;
use AnyEvent;
use AnyEvent::HTTP;

my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10203',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
);
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
    isa_ok $r, 'Feersum::Client', 'got an object!';
    my $env = {};
    $r->env($env);
    ok $env && ref($env) eq 'HASH';

    ok $env->{'psgi.streaming'}, 'got psgi.streaming';
    my $cnum = $env->{HTTP_X_CLIENT};
    ok $cnum, "got client number";

    $cv->begin;
    my $cb = $r->initiate_streaming(sub {
        $started++;
        my $start = shift;
        is ref($start), 'CODE', "streaming handler got a code ref $cnum";
        my $w = $start->("200 OK", ['Content-Type' => 'text/plain']);
        ok blessed($w) && $w->can('write'),
            "after starting, writer can write $cnum";
        my $t; $t = AE::timer 1.5+rand(0.5), 0, sub {
            lives_ok {
                $w->write("So graceful!\n");
                $w->write(undef);
            } "wrote after waiting a little $cnum";
            undef $t; # keep timer alive
            $cv->end;
            $finished++;
        };
    });
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my @got;
sub client {
    my $client_no = shift;
    my $data;
    $cv->begin;
    my $h; $h = AnyEvent::Handle->new(
        connect => ["localhost", 10203],
        on_connect => sub {
            my $to_write = qq{GET /foo HTTP/1.1\nAccept: */*\nX-Client: $client_no\n\n};
            $to_write =~ s/\n/\015\012/smg;
            $h->push_write($to_write);
            undef $to_write;
            $h->on_read(sub {
#             diag "GOT $h->{rbuf}";
                $data .= delete $h->{rbuf};
            });
            $h->on_eof(sub {
                $cv->end;
                push @got, $data;
            });
        },
    );
}


client($_) for (1..CLIENTS);

$cv->begin;
my $grace_t = AE::timer 1.0, 0, sub {
    pass "calling for shutdown";
    $evh->graceful_shutdown(sub {
        pass "all gracefully shut down, supposedly";
        $cv->end;
    });
};
$cv->begin;
my $try_connect = AE::timer 1.4, 0, sub {
    my $h; $h = AnyEvent::Handle->new(
        connect => ["localhost", 10203],
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

use Test::Differences;
my $expect = join("\015\012",
    "HTTP/1.1 200 OK",
    "Content-Type: text/plain",
    "Transfer-Encoding: chunked",
    "",
    "d",
    "So graceful!\n",
    "0"
);
$expect .= "\015\012\015\012";
for my $data (@got) {
    eq_or_diff $data, $expect, "got correctly formatted chunked encoding";
}

pass "all done";
