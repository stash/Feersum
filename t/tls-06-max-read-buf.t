#!perl
# max_read_buf bounds rbuf growth on the TLS read path as it does for plain
# sockets: headers over a lowered max_read_buf get 431 and a chunked body 413,
# rather than accumulating without limit.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    eval { require IO::Socket::SSL; 1 }
        or plan skip_all => "IO::Socket::SSL not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';
    plan tests => 6;
}

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';

use IO::Socket::INET;
use Socket qw(SOMAXCONN);

my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    ReuseAddr => 1,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    Blocking  => 0,
) or die "listen: $!";
my $port = $sock->sockport;

my $f = Feersum->endjinn;
$f->use_socket($sock);
$f->set_tls(cert_file => $cert, key_file => $key);
$f->max_read_buf(16 * 1024);          # 16 KiB read-buffer cap
$f->max_body_len(8 * 1024 * 1024);    # 8 MiB body allowance (> max_read_buf)
$f->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    $env->{'psgi.input'}->read($body, $env->{CONTENT_LENGTH})
        if $env->{CONTENT_LENGTH};
    $r->send_response(200, ['Content-Type' => 'text/plain'],
        [length($body) ? "got=" . length($body) : 'OK']);
});

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    EV::default_loop()->loop_fork;
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break });
    EV::run;
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/32c watchdog timeout\n" };
alarm 90 * TIMEOUT_MULT;

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

sub tls_send {
    my ($request) = @_;
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => "127.0.0.1:$port",
        SSL_verify_mode => 0,
        Timeout         => 5 * TIMEOUT_MULT,
    ) or return undef;
    $cl->autoflush(1);
    print $cl $request;
    local $/;
    my $resp = <$cl>;
    close $cl;
    return $resp;
}

# A small request is served normally.
my $ok = tls_send(
    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
like $ok // '', qr{^HTTP/1\.1 200}, 'small TLS request under cap succeeds';

# A single header line that never terminates: picohttpparser keeps returning
# "incomplete" while rbuf grows past the cap, so only the max_read_buf guard
# can stop it (this is the header-accumulation phase the setting documents).
my $huge = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Pad: "
    . ("A" x (64 * 1024))    # 64 KiB single unterminated header value
    . "\r\n\r\n";
my $big = tls_send($huge);
like $big // '', qr{^HTTP/1\.[01] 431},
    'oversized TLS headers rejected with 431 (fields, not payload - matches plain)';

# Too MANY fields, as opposed to too large.  The TLS read path has its own
# parse branch, so the 431/400 split has to be made there too or the status
# depends on which listener the client happened to reach.
my $many = "GET / HTTP/1.1\r\nHost: localhost\r\n"
    . ("X-H: v\r\n" x 70) . "\r\n";
my $manyr = tls_send($many);
like $manyr // '', qr{^HTTP/1\.[01] 431},
    'more than MAX_HEADERS fields over TLS rejected with 431 (matches plain)';

# A Content-Length body larger than max_read_buf but within max_body_len must
# be accepted: max_read_buf bounds header/chunked accumulation, NOT declared
# body reception (which is governed by max_body_len). This is the plain-path
# behavior; the TLS path must match it and not 413 a legitimate upload.
my $body = "P" x (64 * 1024);   # 64 KiB body: > max_read_buf(16K), < max_body_len(8M)
my $post = tls_send(
    "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: " . length($body)
    . "\r\nConnection: close\r\n\r\n" . $body);
like $post // '', qr{^HTTP/1\.1 200}, 'large Content-Length body under max_body_len succeeds over TLS';
like $post // '', qr{got=65536}, 'full body delivered to handler intact';

# An incomplete chunked body whose decoded bytes exceed max_read_buf must 413.
# Over TLS the post-parse RECEIVE_CHUNKED guard is the sole bound (the plain
# path stops this at the read stage); declare a large chunk, send only part.
my $chunk = sprintf("%x\r\n", 128 * 1024) . ("C" x (64 * 1024));
my $chunked = tls_send(
    "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n"
    . "Connection: close\r\n\r\n" . $chunk);
like $chunked // '', qr{^HTTP/1\.[01] 413},
    'oversized incomplete chunked body over TLS rejected with 413';

alarm 0;
reap_server($pid);
