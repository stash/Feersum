#!perl
use warnings;
use strict;
# TIMEOUT_MULT allows scaling all timing values for slow machines (default: 1)
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More tests => 12;
use Test::Fatal;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

# The shipped default must WARN, not throw.  call_died() invokes it under
# G_EVAL and then clears ERRSV, so a handler that dies reports nothing at all -
# which is exactly what the previous Carp::confess default did.  Checked before
# the override below replaces it.
{
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };
    my $survived = eval { Feersum::DIED("holy crap!\n"); 1 };
    ok $survived, 'default DIED does not throw (a throw here would be swallowed)';
    like $warned[0], qr/holy crap/, 'default DIED warns the error it was passed';
}

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        like $err, qr/holy crap/, 'DIED was called';
    };
}

$evh->request_handler(sub {
    my $r = shift;
    die "holy crap!";
});

is exception {
    $evh->use_socket($socket);
}, undef, 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = simple_client GET => "/?blar", timeout => 2 * TIMEOUT_MULT, sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 500, "client got 500";
    is $headers->{'content-type'}, 'text/plain';
    is $body, "Request handler exception\n", 'got expected body';
    $cv->end;
};

$cv->recv;
pass "all done";
