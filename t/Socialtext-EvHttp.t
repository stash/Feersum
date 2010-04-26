# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Socialtext-EvHttp.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 10;
use Test::Exception;
use blib;
use Carp ();
use Guard;
$SIG{__DIE__} = \&Carp::confess;

BEGIN { use_ok('Socialtext::EvHttp') };

use IO::Socket::INET;
my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10203',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
);
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Socialtext::EvHttp->new();
use AnyEvent;

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

dies_ok {
    $evh->request_handler('foo');
} "can't assign regular scalar";

my $cb;
{
    my $g = guard { pass "cv recycled"; };
    $cb = sub { $g; fail "old callback" }
}

lives_ok {
    $evh->request_handler($cb);
} "can assign code block";

undef $cb;
pass "after undef cb";

$cb = sub {
    pass "called back!";
    my $r = shift;
    isa_ok $r, 'Socialtext::EvHttp::Client', 'got an object!';
    eval {
        $r->send_response("200 OK", ['Content-Type' => 'text/plain'], 'Baz!');
    }; warn $@ if $@;
};

lives_ok {
    $evh->request_handler($cb);
} "can assign another code block";

use AnyEvent::HTTP;
use XXX;

my $cv = AE::cv;
$cv->begin;
my $w = http_get 'http://localhost:10203/?qqqqq', timeout => 1, sub {
    WWW($_[1]);
    warn "CLIENT GOT: ".$_[0];
    $cv->end;
};

$cv->recv;

