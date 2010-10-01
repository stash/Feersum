#!perl
use warnings;
use strict;
use Test::More tests => 12;
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
    package Ovrldr;
    use overload q(&{}) => sub { shift->{the_code} }, fallback => 1;
    sub new {
        my $class = shift;
        my $the_code = shift;
        my $self = bless { the_code => $the_code }, $class;
        return $self;
    }
}

my $APP = <<'EOAPP';
    my $app = Ovrldr->new(sub {
        my $env = shift;
        unless ($env->{'psgi.streaming'}) {
            die "This application needs psgi.streaming support";
        }
        Test::More::pass "called app";
        return Ovrldr->new(sub {
            Test::More::pass "called streamer";
            my $respond = shift;
            my $msg = q({"message":"O hai 1"});
            $respond->([200, ['Content-Type', 'application/json'], [$msg]]);
            Test::More::pass "sent response";
        });
    });
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
}
pass "all done";

