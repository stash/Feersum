#!perl
# set_tls() rejects at configuration time a truncated certificate file and a
# private key that does not match the certificate, and re-registering an SNI
# hostname already present succeeds even when the SNI table is full.
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use File::Temp qw(tempdir);

my $probe = Feersum->new_instance();
plan skip_all => "Feersum not compiled with TLS support" unless $probe->has_tls();

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
plan skip_all => "no test certificates" unless -f $cert && -f $key;

plan tests => 8;

my $dir = tempdir(CLEANUP => 1);

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
sub spew  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1];
            close $fh or die "close $_[0]: $!" }

my ($sock) = get_listen_socket();
my $f = Feersum->new_instance();
$f->use_socket($sock);

# control: the real pair must still be accepted
ok eval { $f->set_tls(cert_file => $cert, key_file => $key); 1 },
    "valid cert+key accepted" or diag $@;

# a certificate file cut off before -----END-----
my $trunc = "$dir/truncated.crt";
spew($trunc, substr(slurp($cert), 0, 400));
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    ok !eval { $f->set_tls(cert_file => $trunc, key_file => $key); 1 },
        "truncated certificate rejected";
    # Not an alternation with picotls's own "failed to load certificate": that
    # message predates this check, so accepting it would let the new DER
    # validation be removed without this test noticing.
    like "@warnings", qr/not valid DER/,
        "truncated certificate names the problem";
}

SKIP: {
    my $openssl = `which openssl 2>/dev/null`;
    chomp $openssl;
    skip "openssl not available to make a second key", 2
        unless $openssl && -x $openssl;
    my $other = "$dir/other.key";
    skip "could not generate a second key", 2
        unless system("$openssl genrsa -out $other 2048 2>/dev/null") == 0;

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    ok !eval { $f->set_tls(cert_file => $cert, key_file => $other); 1 },
        "key that does not match the certificate is rejected";
    like "@warnings", qr/does not match certificate/,
        "mismatched key names the problem";
}

# SNI table: rotation must stay possible when full, new names must not
{
    my ($sock2) = get_listen_socket();
    my $g = Feersum->new_instance();
    $g->use_socket($sock2);
    $g->set_tls(cert_file => $cert, key_file => $key);

    my $added = 0;
    for my $n (1 .. 200) {
        last unless eval {
            $g->set_tls(cert_file => $cert, key_file => $key,
                        sni => "host$n.example");
            1;
        };
        $added++;
    }
    cmp_ok $added, '>', 0, "filled the SNI table ($added entries)";

    ok eval { $g->set_tls(cert_file => $cert, key_file => $key,
                          sni => 'host1.example'); 1 },
        "existing SNI hostname can still be rotated on a full table"
        or diag $@;

    ok !eval { $g->set_tls(cert_file => $cert, key_file => $key,
                           sni => 'brand-new.example'); 1 },
        "a new SNI hostname on a full table still croaks";
}
