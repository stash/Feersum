#!perl
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
use Test::More;
use File::Temp qw(tempfile);
use IO::Socket::INET;

use lib 't'; use Utils;

# sendfile is Linux-only
unless ($^O eq 'linux') {
    plan skip_all => 'sendfile() is only supported on Linux';
}

plan tests => 9;

use_ok('Feersum');

my ($socket, $port) = get_listen_socket();
ok $socket, "made listen socket";

# Create test file
my ($fh, $file) = tempfile(UNLINK => 1);
# Big enough that sendfile() cannot complete in one call: it has to resume
# across EAGAIN.  A few KB is delivered in a single write, so a truncation bug
# (one was found at 4 MB: 4 MB requested, 2.9 MB delivered) is invisible.
print $fh "Hello, sendfile world!\n" x 180_000;  # ~4 MB
close $fh;
my $file_size = -s $file;
ok $file_size > 0, "test file created ($file_size bytes)";

my $evh = Feersum->new();

my $request_handled = 0;
$evh->request_handler(sub {
    my $r = shift;
    open my $fh, '<', $file or die "open: $!";
    my $w = $r->start_streaming("200 OK", [
        'Content-Type' => 'text/plain',
        'Content-Length' => $file_size,
    ]);
    $w->sendfile($fh);
    close $fh;
    $request_handled = 1;
});

$evh->use_socket($socket);

# Use raw socket client instead of AnyEvent (more reliable for sendfile)
my $client = IO::Socket::INET->new(
    PeerAddr => "127.0.0.1:$port",
    Proto    => 'tcp',
    Timeout  => 5,
);
ok $client, "connected to server";

# Send request
print $client "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

# Let server process
my $iterations = 0;
while (!$request_handled && $iterations++ < 100) {
    EV::run(EV::RUN_NOWAIT());
    select(undef, undef, undef, 0.01);
}
ok $request_handled, "request was handled";

# Read response with timeout
my $response = '';
$client->blocking(0);
my $start = time();
while (time() - $start < 30 * TIMEOUT_MULT) {
    my $buf;
    my $n = sysread($client, $buf, 65536);
    if (defined $n && $n > 0) {
        $response .= $buf;
        last if length($response) >= $file_size + 100;  # headers + body
        EV::run(EV::RUN_NOWAIT());
        next;   # data is flowing - do not pace the drain of a multi-MB body
    }
    EV::run(EV::RUN_NOWAIT());
    select(undef, undef, undef, 0.01);
}
close $client;

like $response, qr/^HTTP\/1\.1 200/, "response has HTTP 200 status";
like $response, qr/Hello, sendfile world!/, "response contains file content";

# The assertion that matters: a substring match passes even if only the first
# few bytes arrived.  Compare the delivered body against the file size.
my $sep = index($response, "\r\n\r\n");
cmp_ok $sep, '>=', 0, "response has a header/body separator";
is length($response) - $sep - 4, $file_size,
   "entire $file_size-byte file delivered (no sendfile truncation)";
