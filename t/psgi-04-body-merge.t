#!perl
# Response body merge paths: a single array element up to 4KB merges into the
# header buffer, above that it is a separate iovec, multi-element bodies are
# one iovec each; boundaries at 4096 and 4097 bytes.
use warnings;
use strict;
use Test::More tests => 3 + 7*6; # 7 clients x (5 checks + 1 implicit connect)
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

my $small_body = "x" x 100;
my $boundary_body = "B" x 4096;
my $boundary_plus1 = "C" x 4097;  # first byte above threshold -> large body path
my $large_body = "L" x 8192;

$evh->psgi_request_handler(sub {
    my $env = shift;
    my $path = $env->{PATH_INFO} || '/';
    if ($path eq '/single-small') {
        return [200, ['Content-Type' => 'text/plain'], [$small_body]];
    } elsif ($path eq '/single-boundary') {
        return [200, ['Content-Type' => 'text/plain'], [$boundary_body]];
    } elsif ($path eq '/single-boundary-plus1') {
        return [200, ['Content-Type' => 'text/plain'], [$boundary_plus1]];
    } elsif ($path eq '/single-large') {
        return [200, ['Content-Type' => 'text/plain'], [$large_body]];
    } elsif ($path eq '/multi') {
        return [200, ['Content-Type' => 'text/plain'], ['Hello ', 'World']];
    } elsif ($path eq '/empty') {
        return [200, ['Content-Type' => 'text/plain'], ['']];
    } elsif ($path eq '/many-headers') {
        return [200, [
            'Content-Type'  => 'text/plain',
            'X-One'         => 'a',
            'X-Two'         => 'b',
            'X-Three'       => 'c',
            'X-Four'        => 'd',
            'X-Five'        => 'e',
        ], [$small_body]];
    }
    return [404, ['Content-Type' => 'text/plain'], ['not found']];
});

ok ref($evh), 'handler set';

my $cv = AE::cv;

# 1. Single-element small body (<=4KB) - fast path, merged into header buffer
$cv->begin;
my $h1; $h1 = simple_client GET => '/single-small', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "single-small: 200 OK";
    is $headers->{'content-type'}, 'text/plain', "single-small: content-type";
    is $headers->{'content-length'}, 100, "single-small: content-length";
    is length($body), 100, "single-small: body length";
    is $body, $small_body, "single-small: body content";
    $cv->end; undef $h1;
};

# 2. Boundary body (exactly 4096 bytes) - still fast path
$cv->begin;
my $h2; $h2 = simple_client GET => '/single-boundary', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "boundary: 200 OK";
    is $headers->{'content-type'}, 'text/plain', "boundary: content-type";
    is $headers->{'content-length'}, 4096, "boundary: content-length";
    is length($body), 4096, "boundary: body length";
    is $body, $boundary_body, "boundary: body content";
    $cv->end; undef $h2;
};

# 3. Boundary+1 body (exactly 4097 bytes) - first byte above threshold, large path
$cv->begin;
my $h2b; $h2b = simple_client GET => '/single-boundary-plus1', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "boundary+1: 200 OK";
    is $headers->{'content-type'}, 'text/plain', "boundary+1: content-type";
    is $headers->{'content-length'}, 4097, "boundary+1: content-length";
    is length($body), 4097, "boundary+1: body length";
    is $body, $boundary_plus1, "boundary+1: body content";
    $cv->end; undef $h2b;
};

# 4. Large body (>4KB) - large path, CL in header + body as separate iovec
$cv->begin;
my $h3; $h3 = simple_client GET => '/single-large', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "large: 200 OK";
    is $headers->{'content-type'}, 'text/plain', "large: content-type";
    is $headers->{'content-length'}, 8192, "large: content-length";
    is length($body), 8192, "large: body length";
    is $body, $large_body, "large: body content";
    $cv->end; undef $h3;
};

# 4. Multi-element array body - standard slow path
$cv->begin;
my $h4; $h4 = simple_client GET => '/multi', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "multi: 200 OK";
    is $headers->{'content-type'}, 'text/plain', "multi: content-type";
    is $headers->{'content-length'}, 11, "multi: content-length";
    is length($body), 11, "multi: body length";
    is $body, 'Hello World', "multi: body content";
    $cv->end; undef $h4;
};

# 5. Empty body - fast path with 0 bytes
$cv->begin;
my $h5; $h5 = simple_client GET => '/empty', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "empty: 200 OK";
    is $headers->{'content-type'}, 'text/plain', "empty: content-type";
    is $headers->{'content-length'}, 0, "empty: content-length";
    is length($body), 0, "empty: body length";
    is $body, '', "empty: body content";
    $cv->end; undef $h5;
};

# 6. Many headers + small body - coalesced header buffer + body merge
$cv->begin;
my $h6; $h6 = simple_client GET => '/many-headers', sub {
    my ($body, $headers) = @_;
    is $headers->{'Status'}, 200, "many-headers: 200 OK";
    is $headers->{'x-five'}, 'e', "many-headers: last custom header";
    is $headers->{'content-length'}, 100, "many-headers: content-length";
    is length($body), 100, "many-headers: body length";
    is $body, $small_body, "many-headers: body content";
    $cv->end; undef $h6;
};

$cv->recv;
