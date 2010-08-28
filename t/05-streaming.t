#!perl
use warnings;
use strict;
use constant CLIENTS => 50;
use Test::More tests => 7 + 18 * CLIENTS;
use Test::Exception;
use Test::Differences;
use Scalar::Util qw/blessed/;
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
    my $env = {};
    $r->env($env);
    ok $env && ref($env) eq 'HASH';

    ok $env->{'psgi.streaming'}, 'got psgi.streaming';
    my $cnum = $env->{HTTP_X_CLIENT};
    ok $cnum, "got client number";

    ok !$r->can('write'), "write method removed from connection object";

    $cv->begin;
    my $cb = $r->initiate_streaming(sub {
        $started++;
        my $start = shift;
        is ref($start), 'CODE', "streaming handler got a code ref $cnum";
        my $w = $start->("200 OK", ['Content-Type' => 'text/plain', 'X-Client' => $cnum]);
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
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my @got;
sub client {
    my $client_no = shift;
    my $cnum = sprintf("%04d",$client_no);
    my $data;
    $cv->begin;
    my $h1; $h1 = AnyEvent::Handle->new(
        connect => ["localhost", $port],
        on_connect => sub {
            my $to_write = qq{GET /foo HTTP/1.1\nAccept: */*\nX-Client: $cnum\n\n};
            $to_write =~ s/\n/\015\012/smg;
            $h1->push_write($to_write);
            undef $to_write;
            $h1->on_read(sub {
#             diag "GOT $h1->{rbuf}";
                $data .= delete $h1->{rbuf};
            });
            $h1->on_eof(sub {
                $cv->end;
                push @got, $data;
            });
        },
    );
}


client($_) for (1..CLIENTS);

$cv->recv;
is $started, CLIENTS, 'handlers started';
is $finished, CLIENTS, 'handlers finished';

use Test::Differences;
my $template = join("\015\012",
    "HTTP/1.1 200 OK",
    "Content-Type: text/plain",
    "X-Client: CNUM",
    "Transfer-Encoding: chunked",
    "",
    "26",
    "CNUM Hello streaming world! chunk one\n",
    "28",
    "CNUM Hello streaming world! chunk 'two'\n",
    "28",
    "CNUM Hello streaming world! chunk three\n",
    "0",
    "\015\012",
);
for my $data (@got) {
    my $cnum = '??';
    if ($data =~ /X-Client: (\d{4})/s) { $cnum = $1 }
    (my $expect = $template) =~ s/CNUM/$cnum/sg; # doesn't change chunk size
    eq_or_diff $data, $expect, "got correctly formatted chunked encoding $cnum";
}

pass "all done";
