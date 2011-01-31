#!perl
use warnings;
use strict;
use Test::More tests => 25;
use Test::Fatal;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
$evh->use_socket($socket);

{
    package My::MagicScalar;
    use Tie::Scalar;
    use base 'Tie::StdScalar';
    sub FETCH {
        my $self = shift;
        return uc($self->SUPER::FETCH(@_));
    }
}

{
    package My::MagicArray;
    use Tie::Array;
    use base 'Tie::StdArray';
    sub FETCH {
        my $self = shift;
        my $e = $self->SUPER::FETCH(@_);
        return ref($e) ? $e : uc($e);
    }
    sub SHIFT {
        my $self = shift;
        my $e = $self->SUPER::SHIFT(@_);
        return ref($e) ? $e : uc($e);
    }
}

$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';
    my $env = $r->env();
    ok $env, "got env";

    my $type = $env->{HTTP_X_MAGIC_TYPE};
    if ($type eq 'SCALAR') {
        # magic scalar
        tie my $ms, 'My::MagicScalar';
        $ms = "foobar";
        is exception {
            $r->send_response("200 OK", [
                'Content-Type' => 'text/plain',
            ], \$ms);
        }, undef, "sent response for $type";
    }
    elsif ($type eq 'ARRAY') {
        # magic array
        tie my @ma, 'My::MagicArray';
        @ma = ("aaaa","bbb");
        is exception {
            $r->send_response("200 OK", [
                'Content-Type' => 'text/plain',
            ], \@ma);
        }, undef, "sent response for $type";
    }
    else {
        tie my $ms, 'My::MagicScalar';
        $ms = "dddd";
        tie my @ma, 'My::MagicArray';
        @ma = ("cccc",\$ms);
        is exception {
            $r->send_response("200 OK", [
                'Content-Type' => 'text/plain',
            ], \@ma);
        }, undef, "sent response for $type";
    }
});

my $cv = AE::cv;
$cv->begin;

my $w = simple_client GET => '/',
    name => 'scalar',
    headers => { 'X-Magic-Type' => 'SCALAR' },
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client 1 got 200";
        is $hdr->{'content-length'}, 6, 'content-length was overwritten by the engine';
        is $body, 'FOOBAR', "magic body used for scalar";
        $cv->end;
    };

$cv->begin;
my $w2 = simple_client GET => '/',
    name => 'array',
    headers => { 'X-Magic-Type' => 'ARRAY' },
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client 1 got 200";
        is $hdr->{'content-length'}, 7, 'content-length';
        is $body, 'AAAABBB', "magic body used for array";
        $cv->end;
    };

$cv->begin;
my $w3 = simple_client GET => '/',
    name => 'array',
    headers => { 'X-Magic-Type' => 'SCALAR-in-ARRAY' },
    timeout => 3,
    sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, "client 1 got 200";
        is $hdr->{'content-length'}, 8, 'content-length';
        is $body, 'CCCCDDDD', "magic body used for scalar in array";
        $cv->end;
    };

$cv->recv;
pass "all done";
