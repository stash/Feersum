#!perl
use warnings;
use strict;
use Test::More tests => 13;
use blib;
use Carp ();
use Guard;
use Encode();
use Scalar::Util qw/blessed/;
use utf8;
$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

BEGIN { use_ok('Feersum') };

use IO::Socket::INET;
my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10203',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
);
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
use AnyEvent;

my $cv = AE::cv;

$evh->use_socket($socket);
$evh->request_handler(sub {
    my $r = shift;
    my %env;
    $r->env(\%env);
    my $cl = $env{CONTENT_LENGTH};
    my $input = $env{'psgi.input'};
    ok blessed($input) && $input->can('read'), "got input handle";

    # once streaming input is in place the test method here may need to change
    # to allow for EAGAIN reads.
    my $body = '';
    my $read = $input->read($body, 1);
    is $body, 't', "got first letter";
    is $read, 1, "read just one byte";
    $read = $input->read($body, $cl);
    is $body, 'this is the post body', "buffer has whole body now";
    is $read, $cl-1, "read the rest of the content";

    $read = $input->read($body, 1);
    is $read, 0, "EOF";

    $r->send_response(200, ['Content-Type' => 'text/plain'], [uc $body]);
    pass "sent response";
});


use AnyEvent::HTTP;

$cv->begin;
my $w = http_post 'http://localhost:10203/uppercase', 'this is the post body',
timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, 'ok';
    is $body, 'THIS IS THE POST BODY', 'uppercased';
    $cv->end;
};

$cv->recv;
pass "all done";
