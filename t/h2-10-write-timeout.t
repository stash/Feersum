#!perl
# Test H2 per-stream write timeout - stalled streams get RST_STREAM
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();
plan skip_all => "Feersum not compiled with H2 support"
    unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates"
    unless -f $cert_file && -f $key_file;

my $nghttp_bin = `which nghttp 2>/dev/null`;
chomp $nghttp_bin;
plan skip_all => "nghttp not found in PATH"
    unless $nghttp_bin && -x $nghttp_bin;

plan tests => 5;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "TLS+H2 configured";

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

# Set a short write timeout
my $wt = 1.0 * TIMEOUT_MULT;
$evh->write_timeout($wt);

# The writer must OUTLIVE the handler: if it goes out of scope its DESTROY
# completes the response, so nothing ever stalls and the timeout cannot fire.
my @keep_writers;
# Streaming response that writes once then stops - should trigger timeout
$evh->request_handler(sub {
    my $r = shift;
    my $path = $r->env->{PATH_INFO} // '';
    if ($path eq '/ok') {          # control endpoint, answers normally
        $r->send_response(200, ['Content-Type' => 'text/plain'], ['CONTROLOK']);
        return;
    }
    my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
    $w->write("hello");
    push @keep_writers, $w;
    # Intentionally never write again and never close - let timeout fire
});

# nghttp will get a partial response then RST_STREAM (or connection close)
run_client "H2 write timeout", sub {
    # Control first: nghttp exits 0 even when it cannot connect at all, so
    # without this the whole test passes against a dead server.
    my $ctl = `$nghttp_bin --no-verify -t 10 https://127.0.0.1:$port/ok 2>/dev/null`;
    unless (($? >> 8) == 0 && $ctl =~ /CONTROLOK/) {
        warn "control request failed: nghttp cannot talk to this server\n";
        return 2;
    }
    # The stalled stream must be reset by write_timeout.  Require the actual
    # RST_STREAM frame: nghttp exits 0 either way, and only -v prints frames,
    # so anything weaker passes with the feature disabled.
    my $output = `$nghttp_bin -v --no-verify -t ${\(int($wt + 5))} https://127.0.0.1:$port/hang 2>&1`;
    unless ($output =~ /RST_STREAM/) {
        warn "no RST_STREAM: the stalled stream was never reset\n";
        return 1;
    }
    return 0;
};

pass "done";
