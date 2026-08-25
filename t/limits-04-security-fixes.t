#!perl
# Security fixes regression tests
use warnings;
use strict;
use Test::More tests => 11;
use lib 't'; use Utils;

require Feersum;

# 1. SIGPIPE is ignored at BOOT (no accept_on_fd needed).
# Must run in a clean subprocess: `$SIG{PIPE} || 'IGNORE'` could never fail
# (undef || 'IGNORE' is 'IGNORE'), and t/Utils.pm sets $SIG{PIPE} = 'IGNORE'
# itself at load time, before Feersum is even required.
{
    # List-form open: a shell would expand $SIG before perl ever saw it.
    my $sigpipe = 'undef';
    if (open my $probe, '-|', $^X, '-Mblib', '-MFeersum',
                        '-e', 'print $SIG{PIPE} // q(undef)') {
        chomp($sigpipe = do { local $/; <$probe> } // 'undef');
        close $probe;
    }
    is $sigpipe, 'IGNORE', 'SIGPIPE ignored at Feersum module load (BOOT)';
}

SKIP: {
    my $f = Feersum->endjinn;
    skip "H2 not compiled in", 4 unless $f->has_h2();

    # 2. max_h2_concurrent_streams clamped to FEER_H2_MAX_CONCURRENT_STREAMS (100)
    my $orig = $f->max_h2_concurrent_streams();
    is $f->max_h2_concurrent_streams(500), 100,
        'max_h2_concurrent_streams clamps 500 -> 100';
    is $f->max_h2_concurrent_streams(9999), 100,
        'max_h2_concurrent_streams clamps 9999 -> 100';
    is $f->max_h2_concurrent_streams(50), 50,
        'max_h2_concurrent_streams accepts 50';
    is $f->max_h2_concurrent_streams(0), 1,
        'max_h2_concurrent_streams clamps 0 -> 1';
    $f->max_h2_concurrent_streams($orig);
}

SKIP: {
    my $f = Feersum->endjinn;
    skip "TLS not compiled in", 2 unless $f->has_tls();

    # Need a listener so set_tls has a target
    use IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        LocalAddr => 'localhost:0', ReuseAddr => 1,
        Proto => 'tcp', Listen => 1, Blocking => 0,
    );
    skip "couldn't make listener", 2 unless $sock;
    $f->use_socket($sock);

    my $cert = 't/certs/alpha.crt';
    my $key  = 't/certs/alpha.key';
    skip "test certs not found", 2 unless -f $cert && -f $key;

    # Set default TLS (no h2) so SNI has something to validate against
    $f->set_tls(cert_file => $cert, key_file => $key);

    # 3. SNI entry rejects h2 flag (listener-wide, not per-SNI)
    my $err;
    eval { $f->set_tls(sni => 'host.test', cert_file => $cert, key_file => $key, h2 => 1) };
    $err = $@;
    like $err, qr/h2.*listener-wide/,
        'set_tls(sni=>..., h2=>1) croaks (h2 is listener-wide)';

    # But sni without h2 works
    eval { $f->set_tls(sni => 'other.test', cert_file => $cert, key_file => $key) };
    is $@, '', 'set_tls(sni=>..., no h2) succeeds';

    $f->unlisten();
}

# 4. _drop_privs logic: unknown user/group rejected
require Feersum::Runner;
{
    my $err;
    my $r = Feersum::Runner->new(listen => ['localhost:0'], quiet => 1,
        user => '__definitely_no_such_user__xyz');
    eval { $r->_drop_privs };
    $err = $@;
    like $err, qr/Unknown user/, '_drop_privs rejects unknown user';

    $r = Feersum::Runner->new(listen => ['localhost:0'], quiet => 1,
        group => '__definitely_no_such_group__xyz');
    eval { $r->_drop_privs };
    $err = $@;
    like $err, qr/Unknown group/, '_drop_privs rejects unknown group';
}

# 5. _drop_privs happy path: real group+user drop. Needs root, so this runs
#    on the container/VM CI jobs and skips elsewhere. Regression for the gid
#    verification: $( reads back as "gid gid" after a successful drop (real
#    gid + one-entry setgroups list), which the old single-token check
#    mistook for failure.
SKIP: {
    skip "needs root", 2 if $^O eq 'MSWin32' || $> != 0;
    my @pw = getpwnam('nobody');
    skip "no 'nobody' user", 2 unless @pw;
    my ($uid, $gid) = @pw[2, 3];
    my $group = getgrgid($gid);
    skip "no group name for gid $gid", 2 unless defined $group;

    my $pid = fork();
    skip "fork failed: $!", 2 unless defined $pid;
    if (!$pid) {
        # child: drop for real, report via exit code (1=croak, 2=uid not
        # dropped, 3=stale supplemental groups)
        my $r = Feersum::Runner->new(listen => ['localhost:0'], quiet => 1,
            user => 'nobody', group => $group);
        eval { $r->_drop_privs };
        if ($@) { print STDERR "# _drop_privs died: $@"; POSIX::_exit(1) }
        POSIX::_exit(2) unless $< == $uid && $> == $uid;
        my @rg = split ' ', $(;
        POSIX::_exit(3) if !@rg || grep { $_ != $gid } @rg;
        POSIX::_exit(0);
    }
    waitpid($pid, 0);
    my ($code, $sig) = ($? >> 8, $? & 127);
    is $code, 0, "_drop_privs drops to nobody/$group (child code $code)";
    is $sig, 0, 'drop child exited normally';
}
