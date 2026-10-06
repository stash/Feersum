#!perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use Plack::Handler::Feersum;

use constant TMULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
my ($listen, $port) = get_listen_socket();
die "listen: $!" unless $listen;
my $f = Feersum->new_instance;
$f->use_socket($listen);
my @entries;
my $handler = Plack::Handler::Feersum->new(access_log => sub { push @entries, [@_] });
$handler->{endjinn} = $f;
$handler->assign_request_handler(sub { [200, [], ['logged']] });

my $done = AE::cv;
my $client = simple_client GET => '/logged', port => $port, timeout => 5 * TMULT,
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 200, 'PSGI adapter serves the request';
        is $body, 'logged', 'PSGI response is complete';
        $done->send;
    };
$done->recv;
is scalar(@entries), 1, 'the Plack adapter installs the configured access log';
is_deeply [map { [@$_[0, 1]] } @entries], [['GET', '/logged']],
    'access log receives the completed request';
$f->unlisten;
done_testing;
