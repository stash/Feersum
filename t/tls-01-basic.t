use strict;
use warnings;
use Test::More;
use blib;
use Feersum;

# Check TLS support at compile time
my $evh = Feersum->new();

plan skip_all => "Feersum not compiled with TLS support"
    unless $evh->has_tls();

diag "TLS support: " . ($evh->has_tls() ? "yes" : "no");
diag "H2 support: " . ($evh->has_h2() ? "yes" : "no");

# Test has_tls / has_h2 return values
# plan skip_all above already bailed unless has_tls(), so `ok has_tls()` could
# never fail; assert the exact flag value instead.  Likewise has_h2 is an XS
# `int` returning literal 1/0, so defined() was unfalsifiable.
is $evh->has_tls(), 1, "has_tls returns 1";
# has_h2 depends on Alien::nghttp2 being available at build time
like $evh->has_h2(), qr/^[01]$/, "has_h2 returns a 0/1 flag";

# Test set_tls requires listeners
eval { $evh->set_tls(cert_file => '/nonexistent.crt', key_file => '/nonexistent.key') };
like $@, qr/no listeners/, "set_tls requires listeners";

# Test set_tls parameter validation
my ($socket, $port);
{
    require IO::Socket::INET;
    require Socket;
    my $s = IO::Socket::INET->new(
        LocalAddr => 'localhost',
        LocalPort => 0,
        Proto => 'tcp',
        Listen => Socket::SOMAXCONN(),
        Blocking => 0,
    );
    ($socket, $port) = ($s, $s ? $s->sockport : undef);
}

SKIP: {
    skip "couldn't bind socket", 4 unless $socket;

    # Create a fresh server for socket tests
    my $evh2 = Feersum->new_instance();
    $evh2->use_socket($socket);

    eval { $evh2->set_tls() };
    like $@, qr/key => value/, "set_tls requires key/value pairs";

    eval { $evh2->set_tls(cert_file => 'server.crt') };
    like $@, qr/key_file/, "set_tls requires key_file";

    eval { $evh2->set_tls(key_file => 'server.key') };
    like $@, qr/cert_file/, "set_tls requires cert_file";

    # Test with nonexistent files
    eval { $evh2->set_tls(cert_file => '/nonexistent.crt', key_file => '/nonexistent.key') };
    like $@, qr/failed/, "set_tls fails with nonexistent cert";
}

# Test with real certificate files if available
SKIP: {
    my $cert_file = 'eg/ssl-proxy/server.crt';
    my $key_file  = 'eg/ssl-proxy/server.key';
    skip "no test certificates", 1 unless -f $cert_file && -f $key_file;
    skip "couldn't bind socket", 1 unless $socket;

    my $evh3 = Feersum->new_instance();
    my $socket3 = IO::Socket::INET->new(
        LocalAddr => "localhost:0",
        ReuseAddr => 1,
        Proto => 'tcp',
        Listen => Socket::SOMAXCONN(),
        Blocking => 0,
    );
    skip "couldn't bind second socket", 1 unless $socket3;

    $evh3->use_socket($socket3);
    eval { $evh3->set_tls(cert_file => $cert_file, key_file => $key_file) };
    is $@, '', "set_tls succeeds with valid cert/key";
}

# Test TLS cert rotation (double set_tls)
SKIP: {
    my $cert_file = 'eg/ssl-proxy/server.crt';
    my $key_file  = 'eg/ssl-proxy/server.key';
    skip "no test certificates", 2 unless -f $cert_file && -f $key_file;

    my $evh4 = Feersum->new_instance();
    my $socket4 = IO::Socket::INET->new(
        LocalAddr => "localhost:0",
        ReuseAddr => 1,
        Proto => 'tcp',
        Listen => Socket::SOMAXCONN(),
        Blocking => 0,
    );
    skip "couldn't bind socket", 2 unless $socket4;

    $evh4->use_socket($socket4);
    eval { $evh4->set_tls(cert_file => $cert_file, key_file => $key_file) };
    is $@, '', "first set_tls succeeds";

    # Call set_tls again (cert rotation) - should free old context and create new
    eval { $evh4->set_tls(cert_file => $cert_file, key_file => $key_file) };
    is $@, '', "second set_tls succeeds (cert rotation)";
}

# SNI dedup: re-adding the same hostname must replace, not append.
# Otherwise FEER_MAX_SNI_ENTRIES (32) would croak after 32 rotations.
SKIP: {
    my $cert_file = 'eg/ssl-proxy/server.crt';
    my $key_file  = 'eg/ssl-proxy/server.key';
    skip "no test certificates", 1 unless -f $cert_file && -f $key_file;

    my $evh5 = Feersum->new_instance();
    my $socket5 = IO::Socket::INET->new(
        LocalAddr => "localhost:0",
        ReuseAddr => 1,
        Proto => 'tcp',
        Listen => Socket::SOMAXCONN(),
        Blocking => 0,
    );
    skip "couldn't bind socket", 1 unless $socket5;

    $evh5->use_socket($socket5);
    # Default ctx required so SNI entries have something to attach to
    $evh5->set_tls(cert_file => $cert_file, key_file => $key_file);

    # Add the same SNI host 64 times (twice the cap).  If dedup fails the
    # 33rd call would croak "too many SNI entries".
    my $err;
    for my $i (1..64) {
        eval { $evh5->set_tls(sni => 'rotate.test', cert_file => $cert_file, key_file => $key_file) };
        if ($@) { $err = "iter $i: $@"; last }
    }
    is $err, undef, "SNI dedup: rotating same hostname does not append";
}

done_testing;
