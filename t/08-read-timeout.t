#!perl
use warnings;
use strict;
use constant HARDER => $ENV{RELEASE_TESTING} ? 10 : 1;
use constant POST_CLIENTS => HARDER*1;
use constant GET_CLIENTS => HARDER*1;
use constant GOOD_CLIENTS => HARDER*1;
use Test::More tests =>
    17 + 2*POST_CLIENTS + 2*GET_CLIENTS + 4*GOOD_CLIENTS;
use Test::Exception;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
lives_ok { $evh->use_socket($socket) };
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    ok $env->{HTTP_X_GOOD_CLIENT}, "got a request from a good client";
    $r->send_response(200, ["Content-Type" => "text/plain"], "thx.");
});

my $default = $evh->read_timeout;
is $default, 5.0, "default timeout is 5 seconds";

dies_ok { $evh->read_timeout(-1.0) } "can't set a negative number";
is $evh->read_timeout, 5.0;

dies_ok {
    no warnings 'numeric';
    $evh->read_timeout("this isn't a number");
} "can't set a string as the timeout";
is $evh->read_timeout, 5.0;

lives_ok { $evh->read_timeout(6+1) } "IV is OK";
is $evh->read_timeout, 7.0, "new timeout set";

lives_ok { $evh->read_timeout("8.0") } "NV-as-string is OK";
is $evh->read_timeout, 8.0, "new timeout set";

lives_ok { $evh->read_timeout($default) } "NV is OK";
is $evh->read_timeout, $default, "reset to default";


my $cv = AE::cv;

sub timeout_get_client {
    my $n = shift;
    $cv->begin;
    my $ot; $ot = AE::timer rand(1), 0, sub {
        my $h; $h = simple_client GET => '/',
            name => "(get $n)",
            timeout => 10,
            skip_head => 1,
        sub {
            my ($body,$headers) = @_;
            is $headers->{Status}, 408, "(get $n) got timeout";
            $cv->end;
            undef $h;
        };
        undef $ot;
    };
}

sub timeout_post_client {
    my $n = shift;
    $cv->begin;
    my $ot; $ot = AE::timer rand(1), 0, sub {
        my $h; $h = simple_client POST => '/',
            name => "(post $n)",
            timeout => 10,
            headers => {
                # C-L with no body puts simple_client into stream mode
                'Content-Length' => 8,
                'Content-Type' => 'text/plain',
            },
        sub {
            my ($body,$headers) = @_;
            is $headers->{Status}, 408, "(post $n) got timeout";
            $cv->end;
            undef $h;
        };
        $h->push_write("o "); # 2 out of claimed 8 bytes
        my $t; $t = AE::timer rand(2.5),0,sub {
            $h->push_write("hai"); # 3 more out of claimed 8 bytes
            undef $t; # keep ref
        };
        undef $ot;
    };
}

sub good_client {
    my $n = "(good $_[0])";
    $cv->begin;
    my $ot; $ot = AE::timer rand(1),0,sub {
        my $h; $h = simple_client POST => "/rad", 
            name => $n,
            headers => {'X-Good-Client' => 1},
            body => 'Here it is!',
        sub {
            my ($body,$headers) = @_;
            is $headers->{Status}, 200, "$n got 200";
            is $body, "thx.", "$n got body";
            $cv->end;
            undef $h; # keep ref
        };
        undef $ot;
    };
}

my $t; $t = AE::timer 20, 0, sub {
    $cv->croak("TOO LONG");
};

$cv->begin;
timeout_get_client($_) for (1 .. GET_CLIENTS);
timeout_post_client($_) for (1 .. POST_CLIENTS);
good_client($_) for (1 .. GOOD_CLIENTS);
$cv->end;

lives_ok { $cv->recv } "no client errors";
pass "all done";
