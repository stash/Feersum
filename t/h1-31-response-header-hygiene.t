#!perl
# An app cannot emit a structurally invalid header block or status line: NUL
# in a name or value, SP/HTAB or a leading SP in a name, an empty name, a
# final non-101 1xx status, "200.5"/"200X", or 600-999 are all rejected.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More;
use lib 't'; use Utils;
use IO::Socket::INET;
use POSIX ();
use Feersum;

# path => [headers-or-status shape, short description]
my @BAD = (
    ['nul-value',  'NUL in a header value'],
    ['nul-name',   'NUL in a header name'],
    ['space-name', 'space in a header name'],
    ['empty-name', 'empty header name'],
    ['lead-space', 'header name starting with a space'],
    ['tab-name',   'HTAB in a header name'],
    ['s150',       '1xx as a final status'],
    ['s100',       '100 as a final status'],
    ['st-600',     'status above 599'],
    ['st-float',   'status string "200.5"'],
    ['st-junkX',   'status string "200X"'],
);

plan tests => 1 + 2 * @BAD + 3;

my ($sock, $port) = get_listen_socket();
ok $sock, "listen socket on port $port";

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    no warnings 'once';
    $Feersum::DIED = sub { };
    my $f = Feersum->new_instance();
    $f->use_socket($sock);
    $f->set_keepalive(1);
    $f->read_timeout(30 * TIMEOUT_MULT);
    $f->header_timeout(30 * TIMEOUT_MULT);
    my %case = (
        'nul-value'  => sub { [200, ['X-Test' => "a\0b"], ['ok']] },
        'nul-name'   => sub { [200, ["X-T\0est" => 'v'], ['ok']] },
        'space-name' => sub { [200, ['X Test' => 'v'], ['ok']] },
        'empty-name' => sub { [200, ['' => 'v'], ['ok']] },
        'lead-space' => sub { [200, [' X' => 'v'], ['ok']] },
        'tab-name'   => sub { [200, ["X\tY" => 'v'], ['ok']] },
        's150'       => sub { [150, ['X-A' => 'b'], ['']] },
        's100'       => sub { [100, ['X-A' => 'b'], ['']] },
        'st-600'     => sub { [600, ['Content-Type' => 'text/plain'], ['x']] },
        'st-float'   => sub { ["200.5", ['Content-Type' => 'text/plain'], ['x']] },
        'st-junkX'   => sub { ["200X", ['Content-Type' => 'text/plain'], ['x']] },
        # Still legal, and must keep working:
        'upgrade'    => sub { [101, ['Upgrade' => 'websocket'], []] },
        'htab-value' => sub { [200, ['X-T' => "a\tb"], ['ok']] },
        'ok'         => sub { [200, ['Content-Type' => 'text/plain'], ['ok']] },
    );
    $f->psgi_request_handler(sub {
        my $env = shift;
        my ($k) = ($env->{PATH_INFO} // '') =~ m{^/(.+)};
        my $c = $case{$k // ''} or return [404, ['Content-Type'=>'text/plain'], ['no']];
        return $c->();
    });
    my $life_timer = EV::timer(120 * TIMEOUT_MULT, 0, sub { EV::break() });
    EV::run();
    POSIX::_exit(0);
}
close $sock;
select undef, undef, undef, 1 * TIMEOUT_MULT;

sub fetch {
    my ($path) = @_;
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port",
                                  Timeout => 10 * TIMEOUT_MULT) or return '';
    syswrite $s, "GET /$path HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";
    my $raw = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10 * TIMEOUT_MULT;
        while (sysread($s, my $c, 4096)) { $raw .= $c }
        alarm 0; 1;
    };
    alarm 0; close $s;
    return $raw;
}

for my $case (@BAD) {
    my ($path, $desc) = @$case;
    my $raw = fetch($path);
    like $raw, qr{^HTTP/1\.1 500 }, "$desc is refused with a 500";
    # The status line must be well formed: three digits then a space.
    like $raw, qr{^HTTP/1\.1 \d{3} \S}, "$desc leaves a parseable status line";
}

# The shapes that are legal must still work.
my $up = fetch('upgrade');
like $up, qr{^HTTP/1\.1 101 }, "101 Switching Protocols is still allowed";
my $htab = fetch('htab-value');
like $htab, qr{^HTTP/1\.1 200 .*X-T: a\tb}s, "HTAB inside a header value is still allowed";
my $ok = fetch('ok');
like $ok, qr{^HTTP/1\.1 200 OK.*\r\n\r\nok$}s, "an ordinary response is unaffected";

reap_server($server);
