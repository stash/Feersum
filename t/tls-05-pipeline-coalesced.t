#!perl
# TLS keepalive pipelining: a body-bearing request plus a pipelined second one
# are both answered whether the records arrive steady-state or coalesced into
# the handshake-completing read, and whether or not the app consumes the body.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;

use constant ROUNDS => 5;    # per client x body-mode combination

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    eval { require IO::Socket::SSL; require Net::SSLeay; 1 }
        or plan skip_all => "IO::Socket::SSL/Net::SSLeay not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';
    plan tests => 4 * ROUNDS;
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
$f->set_keepalive(1);

# /read consumes the request body via psgi.input; /skip leaves it unread so
# the keepalive path has to strip it before parsing the pipelined request.
$f->request_handler(sub {
    my $r = shift;
    my $env = $r->env;
    my $body = '';
    if ($env->{PATH_INFO} =~ m{^/read} and my $cl = $env->{CONTENT_LENGTH}) {
        $env->{'psgi.input'}->read($body, $cl);
    }
    $r->send_response(200, ['Content-Type' => 'text/plain'],
        \("path=$env->{PATH_INFO} got=" . length($body) . ":$body"));
});

my $pid = fork;
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    EV::default_loop()->loop_fork;
    my $life = EV::timer(60 * TIMEOUT_MULT, 0, sub { EV::break });
    EV::run;
    POSIX::_exit(0);
}

local $SIG{ALRM} = sub { kill 'KILL', $pid; die "t/32b watchdog timeout\n" };
alarm 120 * TIMEOUT_MULT;

select undef, undef, undef, 1.0 * TIMEOUT_MULT;

sub reqs_for {
    my ($mode) = @_;    # 'read' or 'skip'
    my $got = $mode eq 'read' ? 5 : 0;
    return (
        "POST /$mode HTTP/1.1\r\nHost: localhost\r\n"
            . "Content-Length: 5\r\nConnection: keep-alive\r\n\r\nhello",
        "GET /b HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        qr{path=/$mode got=$got:}s,
        qr{path=/b got=0:}s,
    );
}

# Steady-state client: handshake first, then both requests as two SSL writes.
sub ssl_round {
    my ($mode) = @_;
    my ($reqA, $reqB, $reA, $reB) = reqs_for($mode);
    my $cl = IO::Socket::SSL->new(
        PeerAddr        => "127.0.0.1:$port",
        SSL_verify_mode => 0,
        Timeout         => 3 * TIMEOUT_MULT,
    ) or return "connect failed: $IO::Socket::SSL::SSL_ERROR";
    $cl->autoflush(1);
    print $cl $reqA;
    print $cl $reqB;
    local $/;
    my $resp = <$cl>;
    close $cl;
    return "no response" unless defined $resp && length $resp;
    return "first response wrong: $resp" unless $resp =~ $reA;
    return "pipelined response missing: $resp" unless $resp =~ $reB;
    return '';
}

# Coalesced client: drive the handshake through memory BIOs, hold the client
# Finished flight, queue both requests behind it as separate records, and
# send everything in ONE TCP write - the server's next read completes the
# handshake and already contains both pipelined requests.
sub coalesced_round {
    my ($mode) = @_;
    my ($reqA, $reqB, $reA, $reB) = reqs_for($mode);

    my $ctx = Net::SSLeay::CTX_new_with_method(Net::SSLeay::TLS_client_method())
        or return "CTX_new failed";
    Net::SSLeay::CTX_set_verify($ctx, Net::SSLeay::VERIFY_NONE(), undef);
    my $ssl  = Net::SSLeay::new($ctx) or return "SSL_new failed";
    my $rbio = Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
    my $wbio = Net::SSLeay::BIO_new(Net::SSLeay::BIO_s_mem());
    Net::SSLeay::set_bio($ssl, $rbio, $wbio);
    Net::SSLeay::set_connect_state($ssl);

    my $cl = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port", Proto => 'tcp',
        Timeout  => 3 * TIMEOUT_MULT,
    ) or return "connect failed: $!";
    $cl->autoflush(1);

    my $flush_wbio = sub {
        my $out = '';
        while ((my $pend = Net::SSLeay::BIO_pending($wbio)) > 0) {
            $out .= Net::SSLeay::BIO_read($wbio, $pend);
        }
        return $out;
    };

    my $err = sub { Net::SSLeay::free($ssl); Net::SSLeay::CTX_free($ctx);
                    close $cl; return $_[0] };

    my $done = 0;
    for (1 .. 20) {
        my $rc = Net::SSLeay::do_handshake($ssl);
        if ($rc == 1) { $done = 1; last }
        return $err->("handshake error")
            unless Net::SSLeay::get_error($ssl, $rc)
                == Net::SSLeay::ERROR_WANT_READ();
        my $out = $flush_wbio->();
        if (length $out) {
            syswrite($cl, $out) == length($out)
                or return $err->("short handshake write");
        }
        my $n = sysread($cl, my $in, 65536);
        return $err->("server closed during handshake") unless $n;
        Net::SSLeay::BIO_write($rbio, $in);
    }
    return $err->("handshake did not complete") unless $done;

    # wbio holds the unsent Finished flight; append both app records.
    Net::SSLeay::write($ssl, $reqA) == length($reqA)
        or return $err->("ssl write A failed");
    Net::SSLeay::write($ssl, $reqB) == length($reqB)
        or return $err->("ssl write B failed");
    my $blob = $flush_wbio->();
    syswrite($cl, $blob) == length($blob)
        or return $err->("short coalesced write");

    my $plain = '';
    my $deadline = time + 6 * TIMEOUT_MULT;
    while (time < $deadline) {
        my $n = sysread($cl, my $in, 65536);
        last if defined $n && $n == 0;    # EOF after Connection: close
        next unless $n;
        Net::SSLeay::BIO_write($rbio, $in);
        while (1) {
            my $chunk = Net::SSLeay::read($ssl, 65536);
            last unless defined $chunk && length $chunk;
            $plain .= $chunk;
        }
        last if $plain =~ $reA && $plain =~ $reB;
    }
    Net::SSLeay::free($ssl);
    Net::SSLeay::CTX_free($ctx);
    close $cl;
    return "no response" unless length $plain;
    return "first response wrong: $plain" unless $plain =~ $reA;
    return "pipelined response missing: $plain" unless $plain =~ $reB;
    return '';
}

for my $mode (qw/read skip/) {
    for my $n (1 .. ROUNDS) {
        is ssl_round($mode), '',
            "steady-state $mode round $n: both pipelined responses";
    }
    for my $n (1 .. ROUNDS) {
        is coalesced_round($mode), '',
            "coalesced $mode round $n: both pipelined responses";
    }
}

alarm 0;
reap_server($pid);
