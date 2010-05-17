#!perl
use warnings;
use strict;
use constant CLIENTS => 5;
use constant POST_CLIENTS => 5;
use constant GOOD_CLIENTS => 5;
use Test::More tests =>
    17 + 4*CLIENTS + 4*POST_CLIENTS + 3*GOOD_CLIENTS;
use Test::Exception;
use Test::Differences;
use Scalar::Util qw/blessed/;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
lives_ok { $evh->use_socket($socket) };
$evh->request_handler(sub {
    my $r = shift;
    my %env;
    $r->env(\%env);
    ok $env{HTTP_X_GOOD_CLIENT}, "got a request from a good client";
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

use AnyEvent::Handle;

my $cv = AE::cv;
my $CRLF = "\015\012";

sub start_client {
    my $n = shift;
    my $on_conn = shift || sub {};
    $cv->begin;
    my $h;
    my $done = sub {
        $cv->end;
        $h->destroy;
    };
    $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1',$port],
        on_error => sub {
            my $hdl = shift;
            fail "handle error";
            $hdl->destroy;
            $cv->croak(join(" ",@_));
        },
        on_connect => sub {
            pass "connected $n";
            $on_conn->($h);
        },
        on_read => sub {
            diag "ignoring extra bytes $n";
        },
    );
    $h->push_read(line => "$CRLF$CRLF", sub {
        my $header = $_[1];
        like $header, qr{^HTTP/1\.\d 408 Request Timeout}, "got a timeout response $n";
        my $cl;
        if ($header =~ m{^Content-Length: (\d+)}m) {
            $cl = $1;
            pass "got a c-l header $n";
        }
        else {
            fail "no c-l header?! $n";
            $done->();
        }

        if ($cl == 0) {
            pass "alright, empty error body $n";
            $done->();
        }
        else {
            $h->push_read(chunk => $cl, sub {
                pass "got error body $n";
                $done->();
            });
        }
    });
    return $h;
}

sub post_client {
    my $n = shift;
    my $t;
    start_client("(post $n)", sub {
        my $h = shift;
        $h->push_write("POST / HTTP/1.0$CRLF");
        $h->push_write("Content-Length: 8$CRLF$CRLF");
        $t = AE::timer 3,0,sub {
            $h->push_write("o hai"); # 5 out of 8 bytes
            undef $t; # keep ref
        };
    });
}

sub good_client {
    my $n = "(good $_[0])";
    $cv->begin;
    my $h; $h = http_get "http://localhost:$port/rad", 
        headers => {'X-Good-Client' => 1},
    sub {
        my ($body,$headers) = @_;
        is $headers->{Status}, 200, "got 200 $n";
        is $body, "thx.", "got body $n";
        $cv->end;
        undef $h; # keep ref
    };
}

my $t; $t = AE::timer 20, 0, sub {
    fail "TOO LONG";
    $cv->croak("TOO LONG");
};

$cv->begin;
good_client($_) for (1 .. GOOD_CLIENTS);
start_client("(get $_)") for (1 .. CLIENTS);
post_client($_) for (1 .. POST_CLIENTS);
$cv->end;

lives_ok { $cv->recv } "no client errors";
pass "all done";
