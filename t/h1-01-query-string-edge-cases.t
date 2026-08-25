#!/usr/bin/env perl
# Test query string edge cases
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $feer = Feersum->new();
$feer->use_socket($socket);

my %captured;

$feer->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    %captured = (
        query       => $r->query,
        QUERY_STRING => $env->{QUERY_STRING},
        PATH_INFO   => $env->{PATH_INFO},
        REQUEST_URI => $env->{REQUEST_URI},
    );
    $r->send_response(200, ['Content-Type' => 'text/plain'], 'OK');
});

###############################################################################
# Test 1: No query string
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/no-query', sub { $cv->send };
    $cv->recv;

    is $captured{query}, '', 'query() returns empty string for no query';
    is $captured{QUERY_STRING}, '', 'QUERY_STRING is empty';
    is $captured{PATH_INFO}, '/no-query', 'PATH_INFO correct';
}

###############################################################################
# Test 2: Empty query string (just ?)
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?', sub { $cv->send };
    $cv->recv;

    is $captured{query}, '', 'query() returns empty for bare ?';
    is $captured{QUERY_STRING}, '', 'QUERY_STRING empty for bare ?';
}

###############################################################################
# Test 3: Simple key=value
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?foo=bar', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'foo=bar', 'query() returns simple query';
    is $captured{QUERY_STRING}, 'foo=bar', 'QUERY_STRING correct';
}

###############################################################################
# Test 4: Multiple parameters
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?a=1&b=2&c=3', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'a=1&b=2&c=3', 'query() returns multiple params';
}

###############################################################################
# Test 5: Percent-encoded characters in query
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    # %20 = space, %26 = &, %3D = =
    my $h = simple_client GET => '/path?name=hello%20world&val=a%3Db', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'name=hello%20world&val=a%3Db',
        'query() preserves percent-encoding';
    is $captured{QUERY_STRING}, 'name=hello%20world&val=a%3Db',
        'QUERY_STRING preserves percent-encoding';
}

###############################################################################
# Test 6: Key without value
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?flag', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'flag', 'query() handles key without value';
}

###############################################################################
# Test 7: Key with empty value
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?key=', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'key=', 'query() handles key with empty value';
}

###############################################################################
# Test 8: Multiple empty separators
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?a=1&&b=2', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'a=1&&b=2', 'query() preserves double ampersand';
}

###############################################################################
# Test 9: Duplicate parameter names
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    my $h = simple_client GET => '/path?x=1&x=2&x=3', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'x=1&x=2&x=3', 'query() preserves duplicate params';
}

###############################################################################
# Test 10: Special characters in query
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    # Plus sign, semicolon (alternative separator), tilde
    my $h = simple_client GET => '/path?a=1+2&b;c=~test', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'a=1+2&b;c=~test', 'query() handles special chars';
}

###############################################################################
# Test 11: Very long query string
###############################################################################
{
    %captured = ();
    my $long_value = 'x' x 4000;  # 4KB value
    my $cv = AE::cv;
    my $h = simple_client GET => "/path?data=$long_value", sub { $cv->send };
    $cv->recv;

    is $captured{query}, "data=$long_value", 'query() handles long query string';
}

###############################################################################
# Test 12: Unicode in query (percent-encoded)
###############################################################################
{
    %captured = ();
    my $cv = AE::cv;
    # %E2%9C%93 = checkmark character
    my $h = simple_client GET => '/path?check=%E2%9C%93', sub { $cv->send };
    $cv->recv;

    is $captured{query}, 'check=%E2%9C%93', 'query() preserves UTF-8 encoding';
}

done_testing;
