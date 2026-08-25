#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;

BEGIN {
    plan skip_all => 'not applicable on win32'
        if $^O eq 'MSWin32';
}

plan tests => 41;

use_ok('Feersum::Runner');

#######################################################################
# Test pre_fork validation
#######################################################################

{
    # pre_fork = 0 is valid: it means single-process (no forking), so
    # construction must succeed
    my $runner = eval {
        Feersum::Runner->new(
            listen => ['localhost:0'],
            pre_fork => 0,
            app => sub { shift->send_response(200, [], []); }
        );
    };
    ok($runner, 'pre_fork=0: valid (single process, no forking)') or diag $@;
}

{
    # Test that Runner accepts valid pre_fork value
    my $runner;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            pre_fork => 2,
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
    };
    ok(!$@, 'pre_fork=2: Runner created without error');
    ok($runner, 'pre_fork=2: Runner object exists');
    undef $Feersum::Runner::INSTANCE;
}

#######################################################################
# Test priority validation
#######################################################################

{
    # Valid priority values should work
    my $runner;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            read_priority => -2,
            write_priority => 0,
            accept_priority => 2,
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
    };
    ok(!$@, 'Valid priorities (-2, 0, 2): Runner created without error');
    ok($runner, 'Valid priorities: Runner object exists');
    undef $Feersum::Runner::INSTANCE;
}

{
    # Invalid read_priority should croak during _prepare
    my $runner;
    my $error;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            read_priority => -3,  # Invalid: below -2
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        # Force _prepare to be called
        $runner->_prepare();
    };
    $error = $@;
    like($error, qr/read_priority must be between -2 and 2/, 'read_priority=-3: rejected with clear error');
    undef $Feersum::Runner::INSTANCE;
}

{
    # Invalid write_priority should croak
    my $runner;
    my $error;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            write_priority => 3,  # Invalid: above 2
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    $error = $@;
    like($error, qr/write_priority must be between -2 and 2/, 'write_priority=3: rejected with clear error');
    undef $Feersum::Runner::INSTANCE;
}

{
    # Invalid accept_priority should croak
    my $runner;
    my $error;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            accept_priority => 5,  # Invalid: above 2
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    $error = $@;
    like($error, qr/accept_priority must be between -2 and 2/, 'accept_priority=5: rejected with clear error');
    undef $Feersum::Runner::INSTANCE;
}

#######################################################################
# Test boundary priority values
#######################################################################

{
    # Priority exactly at -2 (minimum) should work
    my $runner;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            read_priority => -2,
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    ok(!$@, 'read_priority=-2 (boundary): accepted');
    undef $Feersum::Runner::INSTANCE;
}

{
    # Priority exactly at 2 (maximum) should work
    my $runner;
    eval {
        $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            write_priority => 2,
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    ok(!$@, 'write_priority=2 (boundary): accepted');
    undef $Feersum::Runner::INSTANCE;
}

#######################################################################
# Test MAX_PRE_FORK constant exists
#######################################################################

{
    # Verify the constant exists (default 1000, FEERSUM_MAX_PRE_FORK overrides
    # at Runner load time)
    my $max = Feersum::Runner::MAX_PRE_FORK();
    is($max, $ENV{FEERSUM_MAX_PRE_FORK} || 1000, 'MAX_PRE_FORK constant matches default');
}

#######################################################################
# Test flat TLS option assembly
#######################################################################

{
    # tls_cert_file without tls_key_file should croak
    eval {
        my $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            tls_cert_file => 'server.crt',
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    like($@, qr/tls_cert_file requires tls_key_file/, 'tls_cert_file without tls_key_file: croaks');
    undef $Feersum::Runner::INSTANCE;
}

{
    # tls_key_file without tls_cert_file should croak
    eval {
        my $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            tls_key_file => 'server.key',
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    like($@, qr/tls_key_file requires tls_cert_file/, 'tls_key_file without tls_cert_file: croaks');
    undef $Feersum::Runner::INSTANCE;
}

{
    # tls hash + flat options: tls hash takes precedence, no croak about flat options
    eval {
        my $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            tls => { cert_file => 'server.crt', key_file => 'server.key' },
            tls_key_file => 'orphan.key',
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    # Should NOT croak about "tls_key_file requires tls_cert_file"
    # It may croak about TLS support not compiled in, which is fine
    unlike($@, qr/tls_key_file requires tls_cert_file/,
        'tls hash + flat tls_key_file: flat option silently discarded');
    undef $Feersum::Runner::INSTANCE;
}

{
    # tls hash + orphan tls_cert_file: tls hash takes precedence (symmetric to above)
    eval {
        my $runner = Feersum::Runner->new(
            listen => ['localhost:0'],
            tls => { cert_file => 'server.crt', key_file => 'server.key' },
            tls_cert_file => 'orphan.crt',
            quiet => 1,
            app => sub { shift->send_response(200, [], []); }
        );
        $runner->_prepare();
    };
    unlike($@, qr/tls_cert_file requires tls_key_file/,
        'tls hash + flat tls_cert_file: flat option silently discarded');
    undef $Feersum::Runner::INSTANCE;
}

#######################################################################
# hot_restart TLS/h2 normalization: generation children read $self->{tls}
# directly and never run _prepare, so the flat-key fold and the h2 merge
# must live in _normalize_tls_config
#######################################################################

{
    # flat keys fold into a tls hashref
    my $runner = Feersum::Runner->new(
        listen => ['localhost:0'], quiet => 1,
        tls_cert_file => 'c.crt', tls_key_file => 'k.key',
        app => sub { shift->send_response(200, [], []); }
    );
    $runner->_normalize_tls_config;
    is(ref $runner->{tls}, 'HASH', 'flat tls keys fold into a hashref');
    is($runner->{tls}{cert_file}, 'c.crt', 'cert_file folded');
    is($runner->{tls}{key_file}, 'k.key', 'key_file folded');
    ok(!exists $runner->{tls_cert_file}, 'flat cert key consumed');
    undef $Feersum::Runner::INSTANCE;
}

{
    # h2 flag merges into the tls config (so hot_restart children negotiate h2)
    my $runner = Feersum::Runner->new(
        listen => ['localhost:0'], quiet => 1,
        tls => { cert_file => 'c.crt', key_file => 'k.key' }, h2 => 1,
        app => sub { shift->send_response(200, [], []); }
    );
    $runner->_normalize_tls_config;
    is($runner->{tls}{h2}, 1, 'h2 merged into tls config');
    ok(!exists $runner->{h2}, 'top-level h2 consumed');
    undef $Feersum::Runner::INSTANCE;
}

{
    # h2 without any TLS is a hard error
    my $runner = Feersum::Runner->new(
        listen => ['localhost:0'], quiet => 1, h2 => 1,
        app => sub { shift->send_response(200, [], []); }
    );
    eval { $runner->_normalize_tls_config };
    like($@, qr/h2 requires TLS/, 'h2 without tls croaks');
    undef $Feersum::Runner::INSTANCE;
}

{
    # hot_restart path skips _prepare, so it must validate pre_fork itself
    # (an unvalidated non-positive value would fork zero workers yet still
    # unlisten and report ready - a silent outage)
    my $runner = Feersum::Runner->new(listen => ['localhost:0'], quiet => 1,
        hot_restart => 1, app_file => 'nonexistent.psgi', pre_fork => -1,
        app => sub { shift->send_response(200, [], []); });
    eval { $runner->_run_hot_restart_master };
    like($@, qr/pre_fork must be a positive integer/,
        'hot_restart validates pre_fork before forking');
    undef $Feersum::Runner::INSTANCE;
}

{
    # sni without any TLS would be silently ignored - hard error (like h2)
    my $runner = Feersum::Runner->new(
        listen => ['localhost:0'], quiet => 1,
        sni => [ { sni => 'example.com', cert_file => 'c.crt', key_file => 'k.key' } ],
        app => sub { shift->send_response(200, [], []); }
    );
    eval { $runner->_normalize_tls_config };
    like($@, qr/sni requires TLS/, 'sni without tls croaks');
    undef $Feersum::Runner::INSTANCE;
}

{
    # A portless listen spec reached bind() as port 0, so `--listen localhost`
    # came up on an arbitrary port with no diagnostic.
    for my $bad (qw(localhost 0.0.0.0 127.0.0.1 [::1] example.com)) {
        my $r = bless { listen => [$bad] }, 'Feersum::Runner';
        eval { $r->_normalize_listen };
        like($@, qr/has no port/, "portless listen '$bad' is rejected");
    }
    # ...but these carry a port (or cannot), and must still be accepted.
    for my $good ('localhost:0', 'localhost:5999', '[::1]:8080', '::1',
                  '/tmp/feersum-test.sock', './feersum-test.sock') {
        my $r = bless { listen => [$good] }, 'Feersum::Runner';
        ok(eval { $r->_normalize_listen; 1 }, "listen '$good' still accepted")
            or diag $@;
    }
}

{
    # sun_path is ~108 bytes and pack_sockaddr_un only WARNS before
    # truncating, so an over-long path used to bind a PREFIX of itself: the
    # configured path never existed, and every later start failed to bind a
    # stale socket at a path written down nowhere.
    my $long = '/tmp/' . ('x' x 200) . '.sock';
    my $r = bless { listen => [$long] }, 'Feersum::Runner';
    eval { $r->_create_socket($long, 0, 0) };
    like $@, qr/too long/, "an over-long unix listen path is rejected";

    # A path that starts like one but has a non-word first character was
    # exempted from the port check as a path, then bound as a TCP address.
    ok Feersum::Runner::_is_unix_listen('/-foo.sock'),
        "'/-foo.sock' is recognised as a socket path everywhere";
    my $r2 = bless { listen => ['/-foo.sock'] }, 'Feersum::Runner';
    ok(eval { $r2->_normalize_listen; 1 },
        "'/-foo.sock' is not rejected as a portless address")
        or diag $@;
}

pass "all Runner validation tests completed";

{
    # app_file alone cannot satisfy preload_app => 0 when a coderef is given:
    # the coderef wins, so the message must name both requirements.
    my $runner = Feersum::Runner->new(
        listen => ['localhost:0'], pre_fork => 2, preload_app => 0, quiet => 1,
    );
    eval { $runner->run(sub { }) };
    like $@, qr/preload_app => 0 requires app_file and no app coderef/,
        'preload_app => 0 with an app coderef croaks, naming both requirements';
    undef $Feersum::Runner::INSTANCE;
}
