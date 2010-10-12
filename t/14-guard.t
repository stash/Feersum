#!perl
use warnings;
use strict;
use Test::More tests => 22;
use utf8;
use lib 't'; use Utils;
use Guard qw/guard/;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $guard_fired = 0;
my $cv;

my $endjinn = Feersum->new();
$endjinn->use_socket($socket);
$endjinn->request_handler(sub {
    my $r = shift;
    $r->response_guard(guard {
        $guard_fired++;
        fail "guard called (should get cancelled)";
    });
    $r->response_guard->cancel;
    is $guard_fired, 0, "guard didn't fire yet (cancelled)";
    $r->response_guard(guard {
        $guard_fired++;
        $cv->end;
        pass "guard called";
    });
    $r->send_response(200,[],\"OK");
    pass 'sent response';
});


$cv = AE::cv;
$guard_fired = 0;
$cv->begin;
$cv->begin; # for the guard
my $w1 = simple_client GET => '/simple',
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client got 200";
        is $body, 'OK', 'plain old body';
        $cv->end;
    };

$cv->recv;
is $guard_fired, 1, "guard fired only once";
pass 'done simple guard';

$endjinn->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    ok $env->{'psgix.output.guard'}, 'env says the writer has this guard';
    scope_for_writer: {
        my $w = $r->start_streaming(200,[]);
        $w->response_guard(guard {
            $guard_fired++;
            fail "guard called (should get cancelled)";
        });
        $w->response_guard->cancel;
        is $guard_fired, 0, "guard didn't fire yet (cancelled)";
        $w->response_guard(guard {
            $guard_fired++;
            pass "stream writer guard called";
        });
        $w->write("STREAM OK");
        is $guard_fired, 0, "guard didn't fire yet (not closed)";
        $w->close();
    }
    is $guard_fired, 0, "guard didn't fire yet (closed, not gc)";
    pass 'sent response';
});

$cv = AE::cv;
$cv->begin;
$guard_fired = 0;
my $w2 = simple_client GET => '/streamer',
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client got 200";
        is $body, 'STREAM OK', 'plain old body';
        $cv->end;
    };

$cv->recv;
is $guard_fired, 1, "guard fired only once";
pass "all done";
