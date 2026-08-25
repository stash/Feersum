#!perl
# TLS tunnel throughput: large data, multi-message, bidirectional.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent::Handle;

eval { require IO::Socket::SSL; 1 }
    or plan skip_all => "IO::Socket::SSL not installed";

plan skip_all => "Feersum not compiled with TLS support"
    unless Feersum->new()->has_tls();

my $cert_file = 'eg/ssl-proxy/server.crt';
my $key_file  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert_file && -f $key_file;
plan skip_all => "OpenSSL too old for TLS 1.3" unless tls_client_ok();

plan tests => 12;

my $CRLF = "\015\012";

my ($socket, $port) = get_listen_socket();
ok $socket, "listen on $port";

my $feer = Feersum->new();
$feer->use_socket($socket);
$feer->set_tls(cert_file => $cert_file, key_file => $key_file);

# Echo server: read lines, echo with "echo: " prefix, QUIT to close.
$feer->request_handler(sub {
    my $req = shift;
    my $io = $req->io;
    syswrite($io, "HTTP/1.1 101 Switching Protocols${CRLF}"
                 . "Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}");
    my $h = AnyEvent::Handle->new(fh => $io, on_error => sub {});
    my $rd; $rd = sub {
        $h->push_read(line => sub {
            return $_[0]->destroy if $_[1] eq 'QUIT';
            $_[0]->push_write("echo: $_[1]\n");
            $rd->();
        });
    };
    $rd->();
});

ok 1, "server ready";

# Client: TLS connect + upgrade, returns IO::Socket::SSL.
# Uses getline for 101 headers (small, no buffering issue).
sub client_upgrade {
    my $c = IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 15,
    ) or return undef;
    $c->print("GET /tunnel HTTP/1.1${CRLF}Host: localhost${CRLF}"
            . "Upgrade: test${CRLF}Connection: Upgrade${CRLF}${CRLF}");
    my $resp = '';
    while (my $line = $c->getline()) {
        $resp .= $line;
        last if $line eq $CRLF;
    }
    return undef unless $resp =~ /101 Switching/;
    return $c;
}

# ---- 100 small echo round-trips ----
run_client("100-small", sub {
    my $c = client_upgrade() or return 10;
    for my $i (1..100) {
        $c->print("msg-$i\n");
        my $r = $c->getline() // '';
        chomp $r;
        return 11 unless $r eq "echo: msg-$i";
    }
    $c->print("QUIT\n");
    close $c;
    return 0;
});

# ---- 64KB ----
run_client("1x64KB", sub {
    my $c = client_upgrade() or return 10;
    my $data = "B" x 65536;
    $c->print("$data\n");
    my $echo = $c->getline() // '';
    chomp $echo;
    return 11 unless $echo eq "echo: $data";
    $c->print("QUIT\n");
    close $c;
    return 0;
});

# ---- 256KB ----
run_client("1x256KB", sub {
    my $c = client_upgrade() or return 10;
    my $data = "C" x (256 * 1024);
    $c->print("$data\n");
    my $echo = $c->getline() // '';
    chomp $echo;
    return 11 unless length($echo) == length("echo: ") + 256 * 1024;
    $c->print("QUIT\n");
    close $c;
    return 0;
});

# ---- 1MB ----
run_client("1x1MB", sub {
    my $c = client_upgrade() or return 10;
    my $data = "D" x (1024 * 1024);
    $c->print("$data\n");
    my $echo = $c->getline() // '';
    chomp $echo;
    return 11 unless length($echo) == length("echo: ") + 1024 * 1024;
    $c->print("QUIT\n");
    close $c;
    return 0;
});

# ---- bidirectional: send 20 then read 20 ----
run_client("bidir-20", sub {
    my $c = client_upgrade() or return 10;
    for my $i (1..20) { $c->print("bidir-$i\n") }
    for my $i (1..20) {
        my $r = $c->getline() // '';
        chomp $r;
        return 11 unless $r eq "echo: bidir-$i";
    }
    $c->print("QUIT\n");
    close $c;
    return 0;
});
