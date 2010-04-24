# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Socialtext-EvHttp.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 2;
use Test::Exception;
use blib;
use Carp ();
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

use AnyEvent::HTTP;
use XXX;

my $cv = AE::cv;
$cv->begin;
my $w = http_get 'http://localhost:10203/', timeout => 1, sub {
    WWW($_[1]);
    warn "CLIENT GOT: ".$_[0];
    $cv->end;
};

$cv->recv;

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

