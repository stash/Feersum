#!perl
use warnings;
use strict;
use Test::More tests => 21;
use Test::Fatal;
use utf8;
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($listen_socket, $port) = get_listen_socket();
ok $listen_socket, "made listen socket";
ok $listen_socket->fileno, "has a fileno";

my $evh = Feersum->new();

# Enable keep-alive which is needed for pipelining
$evh->set_keepalive(1);

my $request_count = 0;
$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Feersum::Connection', 'got an object!';

    $request_count++;
    my $path = $r->path;

    # Add small delays to verify ordering
    my @res = (
        200,
        ['Content-Type' => 'text/plain'],
        ["Response $request_count: $path"]
    );
    if ($path eq '/test2') {
        my $w; $w = AE::timer 0.1, 0.1, sub {
            undef $w;
            $r->send_response(@res);
        };
    } else { $r->send_response(@res) }
});

is exception {
    $evh->use_socket($listen_socket);
}, undef, 'assigned socket';

my $cv = AE::cv;
$cv->begin;

# Create connection using AnyEvent::Handle
my @responses;
my $h; $h = AnyEvent::Handle->new(
    connect => ['localhost', $port],
    timeout => 5,
    on_error => sub {
        my ($h, $fatal, $msg) = @_;
        fail "client error: $msg";
        $cv->send;
    },
    on_eof => sub {
        # Done handling all responses
        my $responses = join "\n\n", @responses;
        like($responses, qr/Response 1: \/test1.*Response 2: \/test2.*Response 3: \/test3/s,
            'Got all responses in correct order');

        # Verify each response had proper headers
        is(scalar(@responses), 3, 'Got expected number of response parts'); # 3 headers + 3 bodies + trailing empty

        my @parts = map { split /\r\n\r\n/ } @responses;

        # First response
        like($parts[0], qr/^HTTP\/1\.1 200 OK/, 'First response has correct status');
        like($parts[0], qr/Content-Type: text\/plain/, 'First response has content type');
        is($parts[1], "Response 1: /test1", 'First response has correct body');

        # Second response
        like($parts[2], qr/^HTTP\/1\.1 200 OK/, 'Second response has correct status');
        like($parts[2], qr/Content-Type: text\/plain/, 'Second response has content type');
        is($parts[3], "Response 2: /test2", 'Second response has correct body');

        # Third response
        like($parts[4], qr/^HTTP\/1\.1 200 OK/, 'Third response has correct status');
        like($parts[4], qr/Content-Type: text\/plain/, 'Third response has content type');
        like($parts[4], qr/Connection: close/, 'Third response has Connection: close');
        is($parts[5], "Response 3: /test3", 'Third response has correct body');

        is($request_count, 3, 'Handled all three requests');
        $cv->end;
        $h->destroy;
    },
    on_read => sub {
        last unless my $len = length(my $buf = $_[0]->rbuf);
        push @responses, $buf;
        substr $_[0]->rbuf, 0, $len, '';
    }
);

# Send three pipelined requests at once
$h->push_write(
    "GET /test1 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
    "GET /test2 HTTP/1.1\r\nHost: localhost\r\n\r\n" .
    "GET /test3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
);

$cv->recv;
pass "all done";
