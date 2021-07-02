#!perl
use warnings;
use strict;
use Test::More tests => 18;
use Test::Fatal;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my $cb = sub {
    my $r = shift;
    my %env = map { $_ => $r->$_ } qw'method uri path query content_length remote_address remote_port input';
    my %hdr = %{$r->headers(Feersum::HEADER_NORM_LOCASE_DASH)};
    is $hdr{user_agent}, 'FeersumSimpleClient/1.0', 'got a ua!';
    is $env{method}, uc'post', 'method';
    is $env{uri}, '/aaa?a=1', 'uri';
    is $env{path}, '/aaa', 'path';
    is $env{query}, 'a=1', 'query';
    is $env{content_length}, 1000, 'content length 0';
    is $env{content_length}, $hdr{content_length}, 'content length 1';
    is $hdr{content_length}, $r->header('content-length'), 'content length 2';
    is $hdr{content_type}, 'text/plain', 'content type 1 ';
    is $hdr{content_type}, $r->header('content-type'), 'content type 2';
    is $env{remote_address}, '127.0.0.1', 'remote address';
    ok $env{remote_port} =~ /^[1-9][0-9]+$/, 'remote port';
    $env{input}->read((my $body), $env{content_length});
    $env{input}->close;
    my $env = $r->env;
    is $env->{uc'path_info'}, $env{path}, 'env match';
    is $body, ('x' x 1000), 'body';
    eval { $r->send_response(200, [qw'content-type text/plain connection close'], 'baz') };
    warn $@ if $@;
    pass "done request handler";
};
my ($socket, $port) = get_listen_socket();
my $feer = Feersum->new;
$feer->use_socket($socket);
$feer->request_handler($cb);

my $cv = AE::cv;
my $w = simple_client
    POST => '/aaa?a=1',
    body => ('x' x 1000),
    timeout => 3,
    sub { my ($body, $hdr) = @_; is $hdr->{Status}, 200, "got 200"; $cv->send };

$cv->recv;
