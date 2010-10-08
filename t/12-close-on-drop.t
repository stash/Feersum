#!perl
use warnings;
use strict;
use Test::More tests => 14;
use Test::Exception;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();

{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        fail "Died during request handler: $err";
    };
}

$evh->request_handler(sub {
    my $r = shift;
    ok $r, 'got request';
    my $w = $r->start_streaming(200, []);
    $w->write("hello ");
    $w->write("world!\n");
    lives_ok {
        undef $w;
    } 'no death on undef';
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my $cv = AE::cv;

sub client {
    my $cnum = shift;
    my $is_chunked = shift || 0;
    $cv->begin;
    my $h; $h = simple_client GET => '/foo',
        name => "client $cnum",
        timeout => 15,
        proto => $is_chunked ? '1.1' : '1.0',
        headers => {"Accept" => "*/*"},
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 200, "client $cnum got 200"
            or diag $headers->{Reason};
        is $body, "hello world!\n", "client $cnum body";
        $cv->end;
        undef $h;
    };
}


client(1,'chunked');
client(2);

$cv->recv;
pass "all done";
