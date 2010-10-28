#!perl
use warnings;
use strict;
use constant CLIENTS => 3;
use Test::More tests => 4 + 10 * CLIENTS;
use Test::Exception;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $endjinn = Feersum->new();
$endjinn->use_socket($socket);

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
$endjinn->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';
    my $env = $r->env();
    ok $env && ref($env) eq 'HASH';

    my $cnum = $env->{'HTTP_X_CLIENT'};

    $cv->begin;
    my $w = $r->start_streaming("200 OK", ['Content-Type' => 'text/plain', 'X-Client' => $cnum, 'X-Fileno' => $r->fileno ]);
    $started++;
    isa_ok($w, 'Feersum::Connection::Writer', "got a writer $cnum");
    isa_ok($w, 'Feersum::Connection::Handle', "... it's a handle $cnum");
    my @first = (
        "$cnum Hello streaming world! chunk one\n",
        \"$cnum Hello streaming world! chunk two\n",
        undef,
        "$cnum Hello streaming world! chunk three\n",
        \"$cnum Hello streaming world! chunk four\n",
    );
    $w->write_array(\@first);
    $w->close;
    $cv->end;
    pass "$cnum handler completed";
});


sub client {
    my $cnum = sprintf("%04d",shift);
    $cv->begin;
    my $h; $h = simple_client GET => '/foo',
        name => $cnum,
        timeout => 15,
        proto => '1.1',
        headers => {
            "Accept" => "*/*",
            'X-Client' => $cnum,
        },
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 200, "$cnum got 200"
            or diag $headers->{Reason};
        is $headers->{HTTPVersion}, '1.1', "$cnum version";
        is $headers->{'transfer-encoding'}, "chunked", "$cnum got chunked!";
        is_deeply [split /\n/,$body], [
            "$cnum Hello streaming world! chunk one",
            "$cnum Hello streaming world! chunk two",
            "$cnum Hello streaming world! chunk three",
            "$cnum Hello streaming world! chunk four",
        ], "$cnum got all four lines"
            or do {
                warn "descriptor ".$headers->{'x-fileno'}." failed!";
                exit 2;
            };
        $cv->end;
        undef $h;
    };
}


client($_,1) for (1..CLIENTS);

$cv->recv;

pass "all done";
