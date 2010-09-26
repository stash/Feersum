#!perl
use warnings;
use strict;
use Test::More tests => 36;
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
$evh->use_socket($socket);

{
    package Message;
    my $n = 0;
    sub new { return bless {}, 'Message' }
    sub to_json { ++$n; return qq({"message":"O hai $n"}) }
}

sub wait_for_new_message {
    my $cb = shift;
    my $t; $t = AE::timer rand(0.5),0,sub {
        $cb->(Message->new());
        undef $t; # cancel circular-ref
    };
    return;
}

# from the PSGI::FAQ
my $APP = <<'EOAPP';
    my $app = sub {
        my $env = shift;
        unless ($env->{'psgi.streaming'}) {
            die "This application needs psgi.streaming support";
        }
        Test::More::pass "called app";
        return sub {
            Test::More::pass "called streamer";
            my $respond = shift;
            wait_for_new_message(sub {
                my $message = shift;
                my $body = [ $message->to_json ];
                Test::More::pass "sending response";
                undef $env;
                $respond->([200, ['Content-Type', 'application/json'], $body]);
                Test::More::pass "sent response";
            });
        };
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' || diag $@;
$evh->psgi_request_handler($app);

returning_body: {
    my $cv = AE::cv;

    $cv->begin;
    my $h; $h = simple_client GET => '/', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'application/json', "... is JSON";
        ok !$headers->{'transfer-encoding'}, '... no T-E header';
        is $body, q({"message":"O hai 1"}), '... correct body';
        $cv->end;
        undef $h;
    };

    $cv->recv;
    pass "all done app 1";
}

my $APP2 = <<'EOAPP';
    my $app2 = sub {
        my $env = shift;
        unless ($env->{'psgi.streaming'}) {
            die "This application needs psgi.streaming support";
        }
        Test::More::pass "called app2";
        return sub {
            Test::More::pass "called streamer2";
            my $respond = shift;
            wait_for_new_message(sub {
                my $message = shift;
                Test::More::pass "sending response2";
                my $w = $respond->([200, ['Content-Type', 'application/json']]);
                Test::More::pass "started response2";
                $w->write($message->to_json);
                Test::More::pass "done response2";
                $w->close;
                undef $env;
            });
        };
    };
EOAPP

my $app2 = eval $APP2;
ok $app2, 'got app 2' || diag $@;
$evh->psgi_request_handler($app2);

using_writer: {
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'application/json', "... is JSON";
        is $headers->{'transfer-encoding'}, 'chunked', '... was chunked';
        is $body, q({"message":"O hai 2"}), "... correct de-chunked body";
        $cv->end;
        undef $h;
    };
    $cv->recv;
}

using_writer_and_1_0: {
    my $cv = AE::cv;
    $cv->begin;
    my $h2; $h2 = simple_client GET => '/', proto => '1.0', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'application/json', "... is JSON";
        ok !$headers->{'transfer-encoding'}, '... was not chunked';
        is $headers->{'connection'}, 'close', '... got close';
        is $body, q({"message":"O hai 3"}), "... correct body";
        $cv->end;
        undef $h2;
    };
    $cv->recv;
}

pass "all done app 2";
