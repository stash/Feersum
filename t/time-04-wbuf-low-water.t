#!perl
# Test wbuf_low_water: poll_cb fires before buffer is fully drained
use warnings;
use strict;
use Test::More tests => 14;
use Test::Fatal;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

no warnings 'redefine';
*Feersum::DIED = sub { warn "DIED: $_[0]\n" };
use warnings;

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Feersum->new();
is exception { $evh->use_socket($socket) }, undef, "bound to socket";

# Default is 0
is $evh->wbuf_low_water, 0, "wbuf_low_water defaults to 0";

# Test getter/setter
$evh->wbuf_low_water(4096);
is $evh->wbuf_low_water, 4096, "wbuf_low_water set to 4096";

$evh->wbuf_low_water(0);
is $evh->wbuf_low_water, 0, "wbuf_low_water reset to 0";

like exception { $evh->wbuf_low_water(-1) }, qr/non-negative/,
    "negative wbuf_low_water croaks";

# Test with low-water-mark: write a known amount, verify poll_cb fires
# enough times to produce the data.
$evh->wbuf_low_water(8192);

my $cb_count = 0;
my $max_chunks = 5;

$evh->request_handler(sub {
    my $r = shift;
    my $w = $r->start_streaming(200, ["Content-Type" => "text/plain"]);
    # Write first chunk immediately
    $w->write("A" x 4096);
    my $chunks = 1;
    # Use $w (not the callback arg) to keep the writer alive
    $w->poll_cb(sub {
        $cb_count++;
        $chunks++;
        if ($chunks <= $max_chunks) {
            $w->write("B" x 4096);
        }
        if ($chunks >= $max_chunks) {
            $w->poll_cb(undef);
            $w->close();
        }
    });
});

my $cv = AE::cv;
$cv->begin;
# simple_client adds 1 implicit pass for "connected"
my $h; $h = simple_client GET => '/',
    sub {
        my ($body, $headers) = @_;
        is $headers->{Status}, 200, "got 200";
        my $expected = 4096 * $max_chunks;
        ok length($body) > 0, "got body (" . length($body) . " bytes)";
        is length($body), $expected, "body is $expected bytes";
        ok $cb_count >= 1, "poll_cb fired at least once ($cb_count times)";
        $cv->end;
    };

$cv->recv;
pass "done";
