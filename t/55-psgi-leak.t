#!perl
use warnings;
use strict;
use constant CLIENTS => 10;
use Test::More;

BEGIN {
    if (eval q{
        require Test::LeakTrace; $Test::LeakTrace::VERSION >= 0.13
    }) {
        plan tests => 7 + 4*CLIENTS;
    }
    else {
        plan skip_all => "Need Test::LeakTrace >= 0.13 to run this test"
    }
}

use lib 't'; use Utils;
use Test::LeakTrace;
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
$evh->use_socket($socket);

my $APP = <<'EOAPP';
    my $app = sub {
        return [200, ['Content-Type' => 'text/plain'], ['Hello ','World']];
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' || diag $@;
$evh->psgi_request_handler($app);


my $cv = AE::cv;
no_leaks_ok {
    return unless $cv;

    for my $n (1 .. CLIENTS) {
        $cv->begin;
        my $h; $h = simple_client GET => '/',
            name => "($n)",
        sub {
            my ($body, $headers) = @_;
            is $headers->{'Status'}, 200, "($n) Response OK";
            is $headers->{'content-type'}, 'text/plain', "... ($n) is text";
            is $body, 'Hello World', "... ($n) correct body";
            $cv->end;
            undef $h;
        };

    }

    $cv->recv;
    pass "done requests";
    $cv = undef;
} 'request leaks';

$cv = AE::cv;
no_leaks_ok {
    return unless $cv;
    $evh->graceful_shutdown(sub { $cv->send });
    $cv->recv;
    pass "done graceful shutdown";
    undef $cv;
    undef $evh;
} 'graceful shutdown leaks';
