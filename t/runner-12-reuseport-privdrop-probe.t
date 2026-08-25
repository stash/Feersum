#!/usr/bin/env perl
# _verify_reuseport_bind: reuseport workers rebind the listen address as the
# dropped-to user.  When that user cannot (a port under 1024), every worker
# died at birth and respawned forever while the parent served nothing.
use strict;
use warnings;
use Test::More;
use Socket qw(SOCK_STREAM AF_INET inet_aton pack_sockaddr_in SOL_SOCKET SO_REUSEADDR);
use lib 't'; use Utils;

BEGIN {
    plan skip_all => 'not applicable on win32' if $^O eq 'MSWin32';
}

use Feersum::Runner ();

plan skip_all => 'SO_REUSEPORT not available on this platform'
    unless defined &Feersum::Runner::SO_REUSEPORT
       && defined Feersum::Runner::SO_REUSEPORT();

plan tests => 8;

# Hand-built object: _verify_reuseport_bind is reached via _drop_privs, which
# would need a real setuid.  Only the fields the probe reads are needed.
sub probe_runner {
    my (@addrs) = @_;
    return bless {
        _use_reuseport => 1,
        _listen_addrs  => [@addrs],
        backlog        => 5,
    }, 'Feersum::Runner';
}

# 1. A free port: the probe binds, closes, and leaves reuseport enabled.
{
    my ($sock, $port) = get_listen_socket();
    close $sock;   # release it again
    my $r = probe_runner("127.0.0.1:$port");
    my @warnings;
    { local $SIG{__WARN__} = sub { push @warnings, @_ }; $r->_verify_reuseport_bind }
    is $r->{_use_reuseport}, 1, 'bindable address keeps reuseport enabled';
    is scalar(@warnings), 0, '... and warns about nothing';
}

# 2. An address we still listen on - what the probe meets at run time, since
# the parent only closes its sockets after forking.  EADDRINUSE means the
# kernel got past the capability check, so it must read as a pass; otherwise
# every ordinary privdrop deployment would lose reuseport.
{
    my ($sock, $port) = get_listen_socket();
    my $r = probe_runner("127.0.0.1:$port");
    my @warnings;
    { local $SIG{__WARN__} = sub { push @warnings, @_ }; $r->_verify_reuseport_bind }
    is $r->{_use_reuseport}, 1, 'EADDRINUSE keeps reuseport enabled';
    is scalar(@warnings), 0, '... and warns about nothing';
    close $sock;
}

# 3. A privileged port we cannot bind.  Skipped when the test user actually can
# (root, or CAP_NET_BIND_SERVICE, or a lowered ip_unprivileged_port_start):
# then there is no failure to detect and the probe is right to stay enabled.
SKIP: {
    my $can_bind = do {
        socket(my $s, AF_INET, SOCK_STREAM, 0) or skip "socket: $!", 3;
        setsockopt($s, SOL_SOCKET, SO_REUSEADDR, pack("i", 1));
        my $ok = bind($s, pack_sockaddr_in(80, inet_aton('127.0.0.1')));
        close $s;
        $ok ? 1 : 0;
    };
    skip 'this user can bind privileged ports', 3 if $can_bind;

    my $r = probe_runner('127.0.0.1:80');
    my @warnings;
    { local $SIG{__WARN__} = sub { push @warnings, @_ }; $r->_verify_reuseport_bind }
    is $r->{_use_reuseport}, 0, 'unbindable privileged port disables reuseport';
    is scalar(@warnings), 1, '... and says so exactly once';
    like $warnings[0], qr/cannot rebind .*disabling reuseport/s,
        '... naming the address and the fallback';
}

# 4. UNIX listeners are inherited rather than rebound, so the probe skips them:
# binding one here would unlink the live socket out from under the parent.
{
    my $r = probe_runner('/nonexistent-dir-for-feersum-test/sock');
    my @warnings;
    { local $SIG{__WARN__} = sub { push @warnings, @_ }; $r->_verify_reuseport_bind }
    is $r->{_use_reuseport}, 1, 'UNIX listener is skipped, reuseport untouched';
}
