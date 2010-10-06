#!perl
use warnings;
use strict;
use Test::More tests => 35;
use Test::Exception;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();

my $cv = AE::cv;

$evh->use_socket($socket);
$evh->request_handler(sub {
    my $r = shift;
    my $env = $r->env();
    my $cl = $env->{CONTENT_LENGTH};
    my $input = $env->{'psgi.input'};
    ok blessed($input) && $input->can('read'), "got input handle";

    my ($body,$read);
    $body = undef;
    if ($env->{HTTP_X_CLIENT} == 1) {
        $read = $input->read($body, 1);
        is $body, 't', "got first letter";
        is $read, 1, "read just one byte";
        $read = $input->read($body, $cl);
        is $body, 'testing partial reads', "buffer has whole body now";
        is $read, $cl-1, "read the rest of the content";
        $read = $input->read($body, 1);
        is $read, 0, "EOF";
    }
    elsif ($env->{HTTP_X_CLIENT} == 2) {
        $read = $input->read($body, $env->{CONTENT_LENGTH});
        is $read, $env->{CONTENT_LENGTH}, "read whole body";
        is length($body), $env->{CONTENT_LENGTH}, "buffer has whole body";
        is $body, 'testing slurp';
        $read = $input->read($body, 1);
        is $read, 0, "EOF";
    }
    elsif ($env->{HTTP_X_CLIENT} == 3) {
        $read = $input->read($body, 999, -6);
        is $read, 6, "read w/ too-big offset";
        is $body, 'offset', "got the last word";
        $body .= ' ';
        $read = $input->read($body, 7, 5);
        is $read, 7, "read again w/ offset";
        is $body, 'offset testing', "got both words";
    }
    else {
        fail "don't know about client $env->{HTTP_X_CLIENT}";
    }

    lives_ok {
        $input->close();
    } 'closed handle';

    $r->send_response(200, ['Content-Type' => 'text/plain'], [uc $body]);
    pass "sent response";
});


$cv->begin;
my $w = simple_client POST => "/uppercase", 
headers => { 'X-Client' => 1 },
body => 'testing partial reads',
timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, 'ok';
    is $body, 'TESTING PARTIAL READS', 'uppercased';
    $cv->end;
};

$cv->begin;
my $w2 = simple_client POST => "/uppercase", 
headers => { 'X-Client' => 2 },
body => 'testing slurp',
timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, 'ok';
    is $body, 'TESTING SLURP', 'uppercased';
    $cv->end;
};

$cv->begin;
my $w3 = simple_client POST => "/uppercase", 
headers => { 'X-Client' => 3 },
body => 'blah testing offset',
timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, 'ok';
    is $body, 'OFFSET TESTING', 'uppercased and reversed';
    $cv->end;
};

$cv->recv;
pass "all done";
