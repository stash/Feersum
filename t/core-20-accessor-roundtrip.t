#!perl
# Boolean get_*/set_* pairs.  The setters are well covered by feature tests but
# five of the getters had no test at all, so a getter reading the wrong flag
# would have been invisible.  Also checks the flags do not share storage.
use warnings;
use strict;
use Test::More;
use lib 't'; use Utils;
use Feersum;

# Flags that exist on every platform; each is exercised for round-trip and for
# independence from the others.
my @flags = (
    ['keepalive',       'set_keepalive',       'get_keepalive'],
    ['multiprocess',    'set_multiprocess',    'get_multiprocess'],
    ['proxy_protocol',  'set_proxy_protocol',  'get_proxy_protocol'],
    ['psgix_io',        'set_psgix_io',        'get_psgix_io'],
    ['reverse_proxy',   'set_reverse_proxy',   'get_reverse_proxy'],
);

plan tests => 1 + 4 * @flags;

my ($socket, $port) = get_listen_socket();
ok $socket, 'got listen socket';

my $f = Feersum->new();
$f->use_socket($socket);

for my $p (@flags) {
    my ($name, $set, $get) = @$p;
    for my $v (0, 1) {
        $f->$set($v);
        is +($f->$get() ? 1 : 0), $v, "$name: set($v) round-trips through $get()";
    }
}

# Each flag must have its own storage: raising one must not disturb the others.
for my $p (@flags) { my $s = $p->[1]; $f->$s(0) }

for my $p (@flags) {
    my ($name, $set) = @$p;
    $f->$set(1);
    my @hot = grep { my $g = $_->[2]; $f->$g() } @flags;
    is scalar(@hot), 1, "$name: raising it leaves every other flag alone";
    is $hot[0][0] // q{}, $name, "$name: and the one flag set is the right one";
    $f->$set(0);
}
