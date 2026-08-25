#!perl
# H2 error responses carry the same payload as the HTTP/1 twin: date,
# content-type, content-length and a body, not a lone :status HEADERS frame.
use warnings;
use strict;
use constant TIMEOUT_MULT => $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use Time::HiRes qw(time);
use lib 't'; use Utils;

use Feersum;

my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support" unless $evh->has_tls();
plan skip_all => "Feersum not compiled with H2 support"  unless $evh->has_h2();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates ($cert_file / $key_file)"
    unless -f $cert_file && -f $key_file;

eval { require IO::Socket::SSL };
plan skip_all => "IO::Socket::SSL not available" if $@;
plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();

plan tests => 8;

my ($socket, $port) = get_listen_socket();
ok $socket, "got listen socket on port $port";

$evh->use_socket($socket);
eval { $evh->set_tls(cert_file => $cert_file, key_file => $key_file, h2 => 1) };
is $@, '', "set_tls with h2 enabled";

$evh->max_uri_len(64);

use H2Utils;

{ no warnings 'redefine'; *Feersum::DIED = sub { }; }
$evh->psgi_request_handler(sub { die "intentional test error\n" });

# Drive one request and collect the HEADERS payload size, the decoded status
# and the concatenated DATA payload for stream 1.
sub h2_error_exchange {
    my ($port, $method, $path) = @_;

    my $sock = h2_connect($port) or return;

    my $block = hpack_encode_headers(
        [':method',    $method],
        [':path',      $path],
        [':scheme',    'https'],
        [':authority', "127.0.0.1:$port"],
    );
    $sock->syswrite(h2_frame(H2_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM,
                             1, $block));

    my %r = (hdr_len => undef, status => undef, data => '', end => 0);
    my $deadline = time + 5 * TIMEOUT_MULT;
    while (time < $deadline && !$r{end}) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        next unless $f->{stream_id} == 1;
        if ($f->{type} == H2_HEADERS) {
            $r{hdr_len} = length $f->{payload};
            $r{status}  = hpack_decode_status($f->{payload});
            $r{end} = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        elsif ($f->{type} == H2_DATA) {
            $r{data} .= $f->{payload};
            $r{end} = 1 if $f->{flags} & FLAG_END_STREAM;
        }
        elsif ($f->{type} == H2_RST_STREAM) {
            $r{rst} = 1;
            last;
        }
    }

    $sock->syswrite(h2_frame(H2_GOAWAY, 0, 0, pack('NN', 0, 0)));
    select(undef, undef, undef, 0.1);
    $sock->close();
    return \%r;
}

# A lone ":status" is one HPACK byte for the indexed 500/404/... entries and a
# handful for the rest, so anything past this proves the companion headers
# (content-type, cache-control, date, content-length) are on the wire too.
use constant BARE_STATUS_MAX => 8;

h2_fork_test("app exception -> full 500", $port, sub {
    my ($port) = @_;
    my $r = h2_error_exchange($port, 'GET', '/die-test') or exit 1;
    exit 2 unless defined $r->{status} && $r->{status} eq '500';
    exit 3 unless defined $r->{hdr_len} && $r->{hdr_len} > BARE_STATUS_MAX;
    exit 4 unless $r->{data} eq "Request handler exception\n";
    exit 0;
});

h2_fork_test("over-long URI -> full 414", $port, sub {
    my ($port) = @_;
    my $r = h2_error_exchange($port, 'GET', '/' . ('a' x 300)) or exit 1;
    exit 2 unless defined $r->{status} && $r->{status} eq '414';
    exit 3 unless defined $r->{hdr_len} && $r->{hdr_len} > BARE_STATUS_MAX;
    exit 4 unless $r->{data} eq "URI Too Long\n";
    exit 0;
});

# RFC 9110 9.3.2: a HEAD error keeps the headers a GET would send but no body.
h2_fork_test("HEAD error -> headers, no body", $port, sub {
    my ($port) = @_;
    my $r = h2_error_exchange($port, 'HEAD', '/die-test') or exit 1;
    exit 2 unless defined $r->{status} && $r->{status} eq '500';
    exit 3 unless defined $r->{hdr_len} && $r->{hdr_len} > BARE_STATUS_MAX;
    exit 4 unless $r->{data} eq '';
    exit 0;
});
