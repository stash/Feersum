#!perl
# graceful_shutdown is terminal: shutting_down is never cleared, and prepare_cb
# (which owns ev_io_start for accept watchers) skips them while it is set.  A
# use_socket() afterwards used to return success and then accept nothing
# forever - a silent wedge.  It must refuse instead.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 7;
use IO::Socket::INET;
use AnyEvent;
use lib 't'; use Utils;
use Feersum;

sub listener {
    IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
                          Proto => 'tcp', Listen => 1024, ReuseAddr => 1,
                          Blocking => 0);
}

my $f = Feersum->new_instance();
$f->psgi_request_handler(sub { [200, ['Content-Type' => 'text/plain'], ['hi']] });

my $s1 = listener();
ok $s1, 'first listen socket';
ok eval { $f->use_socket($s1); 1 }, 'use_socket before shutdown';

# pause/resume already refuse during shutdown; use_socket must agree.
ok $f->pause_accept, 'pause_accept works before shutdown';
ok $f->resume_accept, 'resume_accept works before shutdown';

my $cv = AE::cv;
my $guard = AE::timer 10 * TIMEOUT_MULT, 0, sub { $cv->send('TIMEOUT') };
$f->graceful_shutdown(sub { $cv->send('done') });
is $cv->recv, 'done', 'graceful_shutdown completed';
undef $guard;

my $s2 = listener();
my $ok = eval { $f->use_socket($s2); 1 };
ok !$ok, 'use_socket after graceful_shutdown refuses instead of wedging';
like $@, qr/terminal|shut/i, 'and says why';
