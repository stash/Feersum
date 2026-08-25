package Feersum::Runner;
use warnings;
use strict;

use EV;
use Feersum;
use Socket qw/SOMAXCONN SOL_SOCKET SO_REUSEADDR AF_INET SOCK_STREAM
              inet_aton pack_sockaddr_in/;
BEGIN {
    # Socket exports these even when unsupported; only a call croaks, so call it.
    eval { Socket->import(qw/AF_INET6 inet_pton pack_sockaddr_in6/); AF_INET6(); 1 }
        or do {
            no warnings 'redefine', 'prototype';
            *AF_INET6 = sub () { undef };
            *inet_pton = sub { undef };
            *pack_sockaddr_in6 = sub { undef };
        };
}
BEGIN {
    # Same croak-on-call trap as AF_INET6 above.
    eval { Socket->import('SO_REUSEPORT'); SO_REUSEPORT(); 1 }
        or do { no warnings 'redefine', 'prototype';
                *SO_REUSEPORT = sub () { undef } };
}
use POSIX ();
use Scalar::Util qw/weaken blessed reftype/;
use List::Util qw/any/;
use Carp qw/carp croak/;
use File::Spec::Functions 'rel2abs';

use constant DEATH_TIMER => 5.0; # seconds
use constant DEATH_TIMER_INCR => 2.0; # seconds
# sun_path is 108 bytes on Linux and 104 on the BSDs/macOS, minus the NUL.
use constant UNIX_PATH_MAX => ($^O =~ /linux/i ? 108 : 104) - 1;
use constant DEFAULT_HOST => 'localhost';
use constant DEFAULT_PORT => 5000;
use constant MAX_PRE_FORK => $ENV{FEERSUM_MAX_PRE_FORK} || 1000;
# Respawn backoff: a worker dying within RESPAWN_INSTANT_DEATH is crash-looping.
use constant RESPAWN_INSTANT_DEATH => 1.0;  # seconds
use constant RESPAWN_BACKOFF_BASE  => 0.1;  # seconds, doubled per failure
use constant RESPAWN_BACKOFF_MAX   => 30.0; # seconds
use constant RESPAWN_MAX_FAILS     => 10;   # then retry at BACKOFF_MAX only
use constant WORKER_READY_BUFSZ    => 256;  # readiness bytes read per wakeup
use constant MAX_PORT              => 65_535;
use constant MIN_LIKELY_PORT       => 1024; # below this, a bare number is ambiguous
use constant PORT_DIGITS           => 5;    # a 5-digit tail is definitely a port
use constant PRIORITY_MIN          => -2;   # libev EV_MINPRI; max is +2
use constant SYSCALL_ERROR         => -1;   # the usual failure return
use constant DEFAULT_STARTUP_TIMEOUT => 10; # seconds
use constant READY_TOKEN_SIZE       => 8;  # daemonize readiness handshake
use constant WSTATUS_SIGNAL_MASK   => 127;  # low 7 bits of a wait() status
use constant WSTATUS_EXIT_SHIFT    => 8;    # high bits hold the exit code
use constant WAIT_ANY_PID          => -1;   # waitpid(): any child
# Retirement exit status; keeps a fast retirement out of the respawn backoff.
use constant EXIT_RETIRED          => 42;
use constant FINAL_REAP_ATTEMPTS   => 100;

# warn() is the daemon logging itself; the unchecked close() calls are cleanup.
## no critic (ErrorHandling::RequireCarping, InputOutput::RequireCheckedClose)

our $INSTANCE;
sub new { ## no critic (RequireArgUnpacking)
    my $c = shift;
    if ($INSTANCE) {
        croak "Only one Feersum::Runner instance can be active at a time"
            if $INSTANCE->{running};
        $INSTANCE->_cleanup();
        undef $INSTANCE;
    }
    $INSTANCE = bless {quiet=>1, @_, running=>0}, $c;
    return $INSTANCE;
}

sub _cleanup {
    my $self = shift;
    return if $self->{_cleaned_up};
    $self->{_cleaned_up} = 1;
    if (my $f = $self->{endjinn}) {
        $f->request_handler(sub{});
        $f->unlisten();
    }
    $self->{_quit} = undef;
    $self->{_term} = undef;
    $self->{_int}  = undef;
    $self->{_hup}  = undef;
    # Left armed, _death would _exit(1) an embedder after run() has returned.
    $self->{_death} = undef;
    $self->{_kids}  = undef;
    $self->{_respawn_timers} = undef;
    $self->{running} = 0;
    $self->_remove_pid_file;
    return;
}

# Only if it still holds our pid; a failed second instance must not unlink it.
sub _remove_pid_file {
    my $self = shift;
    my $file = $self->{pid_file} or return;
    open my $fh, '<', $file or return;
    my $owner = <$fh>;
    close $fh;
    $owner = '' unless defined $owner;
    $owner =~ s/\s+//g;
    return unless $owner eq $$;
    # unlink needs directory write access, which the dropped-to user often lacks.
    unlink($file) or warn "Feersum [$$]: cannot remove pid_file '$file': $!\n";
    return;
}

sub DESTROY {
    my ($self) = @_;
    local $@ = undef;
    $self->_cleanup();
    return;
}

sub _create_socket { ## no critic (ProhibitExcessComplexity)
    my ($self, $listen, $use_reuseport, $no_listen) = @_;
    my $backlog = $self->{backlog} || SOMAXCONN;

    my $sock;
    if (_is_unix_listen($listen)) {
        require IO::Socket::UNIX;
        my $path = rel2abs($listen);
        # pack_sockaddr_un only warns before truncating, binding a prefix of the path.
        croak "listen path '$path' is too long (" . length($path)
            . " bytes; the platform limit for a unix socket is "
            . UNIX_PATH_MAX . ")"
            if length($path) > UNIX_PATH_MAX;
        if (-S $path) {
            unlink $path or carp "unlink stale socket '$path': $!";
        }
        my $saved = umask(0);
        $sock = eval {
            IO::Socket::UNIX->new(
               Local => $path,
               Listen => $backlog,
            );
        };
        my $err = $@;
        umask($saved);
        die $err if $err;
        croak "couldn't bind to socket '$path': $!" unless $sock;
        $sock->blocking(0) || do { close($sock); croak "couldn't unblock socket: $!"; };
    }
    else {
        require IO::Socket::INET;
        # IO::Socket::INET is IPv4-only, so IPv6 takes the manual socket() path.
        my $is_ipv6_form = ($listen =~ /^\[/ || $listen =~ /:.*:/) ? 1 : 0;
        my $want_reuseport = ($use_reuseport && defined SO_REUSEPORT) ? 1 : 0;
        # SO_REUSEPORT must be set before bind.
        if ($want_reuseport || $is_ipv6_form) {
            my ($host, $port, $is_ipv6);
            if ($listen =~ /^\[([^\]]+)\]:(\d*)$/) {
                ($host, $port, $is_ipv6) = ($1, $2 || 0, 1);
            } elsif ($listen =~ /^\[([^\]]+)\]$/) {
                ($host, $port, $is_ipv6) = ($1, 0, 1);
            } elsif ($listen =~ /:.*:/) {
                if ($listen =~ /:(\d{1,5})$/) {
                    my $maybe_port = $1;
                    if ($maybe_port <= MAX_PORT && (length($maybe_port) == PORT_DIGITS || $maybe_port >= MIN_LIKELY_PORT)) {
                        croak "ambiguous IPv6 address '$listen': use bracket notation [host]:port " .
                              "(e.g., [::1]:$maybe_port or [2001:db8::1]:$maybe_port)";
                    }
                }
                ($host, $port, $is_ipv6) = ($listen, 0, 1);
            } else {
                ($host, $port) = split /:/, $listen, 2;
                $host ||= '0.0.0.0';
                $port ||= 0;
                $is_ipv6 = 0;
            }

            if ($port !~ /^\d+$/ || $port > MAX_PORT) {
                croak "invalid port '$port': must be 0-" . MAX_PORT;
            }

            my ($domain, $sockaddr);
            if ($is_ipv6) {
                defined AF_INET6()
                    or croak "IPv6 not supported on this system";
                my $addr = inet_pton(AF_INET6(), $host)
                    or croak "couldn't resolve IPv6 address '$host'";
                $domain = AF_INET6();
                $sockaddr = pack_sockaddr_in6($port, $addr);
            } else {
                my $addr = inet_aton($host)
                    or croak "couldn't resolve address '$host'";
                $domain = AF_INET();
                $sockaddr = pack_sockaddr_in($port, $addr);
            }

            socket($sock, $domain, SOCK_STREAM(), 0)
                or croak "couldn't create socket: $!";
            setsockopt($sock, SOL_SOCKET, SO_REUSEADDR, pack("i", 1))
                or do { close($sock); croak "setsockopt SO_REUSEADDR failed: $!"; };
            if ($want_reuseport) {
                setsockopt($sock, SOL_SOCKET, SO_REUSEPORT, pack("i", 1))
                    or do { close($sock); croak "setsockopt SO_REUSEPORT failed: $!"; };
            }
            bind($sock, $sockaddr)
                or do { close($sock); croak "couldn't bind to socket: $!"; };
            # Probe: listen() would join the reuseport group and attract connections.
            return $sock if $no_listen;
            listen($sock, $backlog)
                or do { close($sock); croak "couldn't listen: $!"; };

            require IO::Handle;
            bless $sock, 'IO::Handle';
            $sock->blocking(0)
                || do { close($sock); croak "couldn't unblock socket: $!"; };
        }
        else {
            if ($listen =~ /:(\d+)$/) {
                my $port = $1;
                croak "invalid port '$port': must be 0-" . MAX_PORT if $port > MAX_PORT;
            } elsif ($listen =~ /:(\S+)$/) {
                my $port = $1;
                croak "invalid port '$port': must be numeric" unless $port =~ /^\d+$/;
            }
            $sock = IO::Socket::INET->new(
                LocalAddr => $listen,
                ReuseAddr => 1,
                Proto => 'tcp',
                Listen => $backlog,
                Blocking => 0,
            );
            croak "couldn't bind to socket: $!" unless $sock;
        }
    }
    return $sock;
}


# One list for cold start and hot_restart, so a new setting cannot miss either.
my @SIMPLE_SETTINGS = (
    [keepalive            => 'set_keepalive'],
    [reverse_proxy        => 'set_reverse_proxy'],
    [proxy_protocol       => 'set_proxy_protocol'],
    [psgix_io             => 'set_psgix_io'],
    [read_timeout         => 'read_timeout'],
    [header_timeout       => 'header_timeout'],
    [write_timeout        => 'write_timeout'],
    [max_connection_reqs  => 'max_connection_reqs'],
    [read_priority        => 'read_priority'],
    [write_priority       => 'write_priority'],
    [accept_priority      => 'accept_priority'],
    [max_accept_per_loop  => 'max_accept_per_loop'],
    [max_connections      => 'max_connections'],
    [max_read_buf         => 'max_read_buf'],
    [max_body_len         => 'max_body_len'],
    [max_uri_len          => 'max_uri_len'],
    [wbuf_low_water       => 'wbuf_low_water'],
    [max_h2_concurrent_streams => 'max_h2_concurrent_streams'],
    [max_h2_conn_body     => 'max_h2_conn_body'],
);

sub _apply_simple_settings {
    my ($self, $f, $consume) = @_;
    for my $pair (@SIMPLE_SETTINGS) {
        my ($opt, $meth) = @$pair;
        my $val = $consume ? delete $self->{$opt} : $self->{$opt};
        $f->$meth($val) if defined $val;
    }
    return;
}

# File-scoped: a watcher in the callback's own pad dies with the callback.
my $RETIRE_DEADLINE;

sub _set_max_requests_per_worker {
    my ($self, $f) = @_;
    my $max = $self->{max_requests_per_worker} or return;
    my $gt = $self->{graceful_timeout}
          // $ENV{FEERSUM_GRACEFUL_TIMEOUT}
          // DEATH_TIMER;
    my $quiet = $self->{quiet};
    $f->max_requests_per_worker($max,
        sub { POSIX::_exit(EXIT_RETIRED) },
        sub {
            # The replacement is forked only after exit, so the drain needs a deadline.
            $RETIRE_DEADLINE = EV::timer($gt, 0, sub {
                $quiet or warn "Feersum [$$]: retirement drain exceeded "
                             . "${gt}s, forcing exit\n";
                POSIX::_exit(EXIT_RETIRED);
            });
        });
    return;
}

sub _apply_tls_to_listeners {
    my ($self, $f, $n_listeners, $tls, $sni) = @_;
    for my $i (0 .. $n_listeners - 1) {
        $f->set_tls(listener => $i, %$tls);
    }
    if ($sni) {
        croak "sni must be an array reference" unless ref $sni eq 'ARRAY';
        for my $entry (@$sni) {
            for my $i (0 .. $n_listeners - 1) {
                $f->set_tls(listener => $i, %$entry);
            }
        }
    }
    return;
}

sub _normalize_listen {
    my $self = shift;
    if (defined $self->{listen} && !ref $self->{listen}) {
        $self->{listen} = [ $self->{listen} ];
    }
    $self->{listen} ||=
        [ ($self->{host}||DEFAULT_HOST) . q{:} . ($self->{port}||DEFAULT_PORT) ];
    croak "listen must be an array reference"
        if ref $self->{listen} ne 'ARRAY';
    croak "listen array cannot be empty"
        if @{$self->{listen}} == 0;
    # An empty or bare-numeric entry would bind 0.0.0.0 on a random port.
    for my $i (0 .. $#{$self->{listen}}) {
        my $l = $self->{listen}[$i];
        croak "listen[$i] is undefined" unless defined $l;
        croak "listen[$i] is empty"     unless length $l;
        croak "listen[$i] '$l' is not an address: use host:port, [ipv6]:port, "
            . "or a socket path" if $l =~ /\A\d+\z/;
        next if _is_unix_listen($l)
             || ($l =~ /\A\[/ ? $l =~ /\]:/ : $l =~ /:/);
        croak "listen[$i] '$l' has no port: use $l:PORT "
            . "(a portless address binds an arbitrary port)";
    }
    $self->{_listen_addrs} = [ @{$self->{listen}} ];
    return;
}

# Must not consume $self->{tls}: hot_restart re-reads it for every generation.
sub _normalize_tls_config {
    my $self = shift;
    if (!$self->{tls}) {
        if (my $cert = delete $self->{tls_cert_file}) {
            my $key = delete $self->{tls_key_file}
                or croak "tls_cert_file requires tls_key_file";
            $self->{tls} = { cert_file => $cert, key_file => $key };
        } elsif (delete $self->{tls_key_file}) {
            croak "tls_key_file requires tls_cert_file";
        }
    } else {
        delete $self->{tls_cert_file};
        delete $self->{tls_key_file};
    }
    if (my $tls = $self->{tls}) {
        croak "tls must be a hash reference" unless ref $tls eq 'HASH';
        croak "tls requires cert_file" unless $tls->{cert_file};
        croak "tls requires key_file" unless $tls->{key_file};
        $tls->{h2} = 1 if delete $self->{h2};
    } elsif (delete $self->{h2}) {
        croak "h2 requires TLS (provide tls_cert_file and tls_key_file, or a tls hash)";
    }
    croak "sni requires TLS (provide tls_cert_file and tls_key_file, or a tls hash)"
        if $self->{sni} && !$self->{tls};
    return;
}

sub _validate_pre_fork {
    my $self = shift;
    return unless $self->{pre_fork};
    my $n = $self->{pre_fork};
    croak "pre_fork must be a positive integer" if $n !~ /^\d+$/ || $n < 1;
    croak "pre_fork=$n exceeds maximum of " . MAX_PRE_FORK if $n > MAX_PRE_FORK;
    return;
}

# The one test for a socket-path spec; every listener path must agree on it.
sub _is_unix_listen {
    my ($listen) = @_;
    return defined($listen) && $listen =~ m{\A[/.]} ? 1 : 0;
}

# Blessed coderefs and &{} overloads count too; call_sv() invokes any of them.
sub _is_callable {
    my ($app) = @_;
    return 0 unless ref $app;
    return 1 if (reftype($app) || q{}) eq 'CODE';
    return 1 if blessed($app) && do { require overload;
                                      overload::Method($app, '&{}') };
    return 0;
}

my $SO_REUSEPORT_WORKS;   # probed once: a kernel property

sub _reuseport_enabled {
    my $self = shift;
    return 0 unless $self->{reuseport} && $self->{pre_fork} && defined SO_REUSEPORT;
    # The constant only proves the headers had it; old kernels fail the setsockopt.
    $SO_REUSEPORT_WORKS //= do {
        my $probe;
        socket($probe, AF_INET, SOCK_STREAM, 0)
            && setsockopt($probe, SOL_SOCKET, SO_REUSEPORT, pack('i', 1))
            ? 1 : 0;
    };
    return $SO_REUSEPORT_WORKS;
}

sub _prepare { ## no critic (ProhibitExcessComplexity)
    my $self = shift;

    $self->_normalize_listen();
    $self->_validate_pre_fork;

    my $use_reuseport = $self->_reuseport_enabled;
    $self->{_use_reuseport} = $use_reuseport;

    my $f = Feersum->endjinn;

    # Before use_socket(): each accept watcher captures accept_priority at creation.
    if (defined $self->{accept_priority}) {
        my $val = $self->{accept_priority};
        croak "accept_priority must be an integer" unless $val =~ /^-?\d+$/;
        croak "accept_priority must be between -2 and 2" if $val < PRIORITY_MIN || $val > 2;
        $f->accept_priority($val);
    }

    my @socks;
    for my $listen (@{$self->{_listen_addrs}}) {
        my $sock = $self->_create_socket($listen, $use_reuseport);
        push @socks, $sock;
        $f->use_socket($sock);
    }
    $self->{sock} = $socks[0];   # backward compat: primary socket
    $self->{_socks} = \@socks;

    for my $prio_name (qw/read_priority write_priority/) {
        my $val = $self->{$prio_name};
        next unless defined $val;
        croak "$prio_name must be an integer" unless $val =~ /^-?\d+$/;
        croak "$prio_name must be between -2 and 2" if $val < PRIORITY_MIN || $val > 2;
    }
    if (defined(my $val = $self->{max_accept_per_loop})) {
        croak "max_accept_per_loop must be a positive integer"
            if $val !~ /^\d+$/ || $val < 1;
    }
    if (defined(my $val = $self->{max_connections})) {
        croak "max_connections must be a non-negative integer"
            unless $val =~ /^\d+$/;
    }
    $self->_apply_simple_settings($f, 1);  # consume from $self

    $self->_normalize_tls_config;

    if (my $tls = delete $self->{tls}) {
        (-f $tls->{cert_file} && -r _)
            or croak "tls cert_file '$tls->{cert_file}': not found or not readable";
        (-f $tls->{key_file} && -r _)
            or croak "tls key_file '$tls->{key_file}': not found or not readable";

        if ($f->has_tls()) {
            $self->_apply_tls_to_listeners($f, scalar(@socks), $tls, $self->{sni});
            $self->{_tls_config} = $tls;  # for reuseport workers
            $self->{quiet} or warn "Feersum [$$]: TLS enabled on "
                . scalar(@socks) . " listener(s)\n";
        } else {
            croak "tls option requires Feersum compiled with TLS support (need picotls submodule + OpenSSL; see Alien::OpenSSL)";
        }
    }

    $self->{endjinn} = $f;
    return;
}

# for overriding:
sub assign_request_handler {
    my ($self, $app) = @_;
    $self->{endjinn}->access_log($self->{access_log});
    return $self->{endjinn}->request_handler($app);
}

sub run { ## no critic (ProhibitExcessComplexity)
    my $self = shift;
    weaken $self;

    $self->{running} = 1;
    my $app = shift || $self->{app};
    $self->{quiet} or warn "Feersum [$$]: starting...\n";

    if ($self->{hot_restart}) {
        croak "hot_restart requires app_file" unless $self->{app_file};
        # Bind before daemonizing so a bind failure reaches the exit status.
        $self->_hot_restart_bind();
        $self->_daemonize_and_write_pid();
        $self->_run_hot_restart_master();
        # DESTROY at interpreter exit misses embedders that _exit after run().
        $self->_cleanup();
        return;
    }

    $self->_prepare();
    $self->_daemonize_and_write_pid();
    $self->_drop_privs();    # after bind, before app load

    # Daemonize + pre_fork gates the ready token on the pool actually coming up.
    my $workers_ok = 1;
    if ($self->{pre_fork} && defined $self->{preload_app} && !$self->{preload_app}) {
        croak "preload_app => 0 requires app_file and no app coderef (a coderef is "
            . "compiled before the fork and cannot be loaded independently per worker)"
            if ($app || $self->{app}) && !$self->{app_file};
        $self->{_app_loader} = sub {
            my $handler = $app || $self->{app};
            if (!$handler && $self->{app_file}) {
                local ($@, $!) = (undef, undef);
                $handler = do(rel2abs($self->{app_file}));
                warn "couldn't load $self->{app_file}: " . ($@ || $!)
                    if $@ || !$handler;
            }
            croak "app not defined or failed to compile" unless $handler;
            croak "app must be callable, got " . (ref($handler) || 'a plain scalar')
                unless _is_callable($handler);
            $self->assign_request_handler($handler);
        };
        $self->{_quit} = EV::signal 'QUIT', sub { $self && $self->quit };
        # Unhandled TERM/INT would orphan the workers with the port still bound.
        $self->{_term} = EV::signal 'TERM', sub { $self && $self->quit };
        $self->{_int}  = EV::signal 'INT',  sub { $self && $self->quit };
        # Unhandled HUP would kill the supervisor and orphan the workers.
        $self->{_hup}  = EV::signal 'HUP',  sub {
            warn "Feersum [$$]: SIGHUP ignored (reload requires hot_restart)\n";
        };
        $workers_ok = $self->_start_pre_fork;
    } else {
        $app ||= delete $self->{app};
        if (!$app && $self->{app_file}) {
            local ($@, $!) = (undef, undef);
            $app = do(rel2abs($self->{app_file}));
            warn "couldn't parse $self->{app_file}: $@" if $@;
            warn "couldn't do $self->{app_file}: $!" if ($! && !defined $app);
            warn "couldn't run $self->{app_file}: didn't return anything"
                unless $app;
        }
        croak "app not defined or failed to compile" unless $app;
        croak "app must be callable, got " . (ref($app) || 'a plain scalar')
            unless _is_callable($app);

        $self->assign_request_handler($app);

        $self->{_quit} = EV::signal 'QUIT', sub { $self && $self->quit };
        # Unhandled TERM/INT would orphan the workers with the port still bound.
        $self->{_term} = EV::signal 'TERM', sub { $self && $self->quit };
        $self->{_int}  = EV::signal 'INT',  sub { $self && $self->quit };
        # Unhandled HUP would kill the supervisor and orphan the workers.
        $self->{_hup}  = EV::signal 'HUP',  sub {
            warn "Feersum [$$]: SIGHUP ignored (reload requires hot_restart)\n";
        };

        $workers_ok = $self->_start_pre_fork if $self->{pre_fork};
    }
    # _exit without the ready token: the daemonize parent sees EOF and fails.
    if (!$workers_ok && !$self->{_shutdown}) {
        warn "Feersum [$$]: workers failed to start\n" unless $self->{quiet};
        POSIX::_exit(1);
    }
    # Everything that can fail at startup has now succeeded.
    $self->_daemon_ready;
    EV::run;
    $self->{quiet} or warn "Feersum [$$]: done\n";
    $self->_cleanup();
    return;
}

# Runs before daemonizing so a bind failure reaches the exit status; idempotent.
sub _hot_restart_bind {
    my ($self) = @_;
    return if $self->{_master_socks};

    $self->_normalize_listen();
    # Generation children never run _prepare, so validate and fold here.
    $self->_validate_pre_fork;
    $self->_normalize_tls_config();

    my $use_reuseport = $self->_reuseport_enabled;
    $self->{_use_reuseport} = $use_reuseport;
    my @socks;
    for my $listen (@{$self->{_listen_addrs}}) {
        my $sock = $self->_create_socket($listen, $use_reuseport);
        push @socks, $sock;
    }
    $self->{_master_socks} = \@socks;
    return;
}

sub _run_hot_restart_master { ## no critic (ProhibitExcessComplexity)
    my ($self) = @_;
    my $quiet = $self->{quiet};

    $quiet or warn "Feersum [$$]: hot restart master starting\n";

    $self->_hot_restart_bind();
    my @socks = @{ $self->{_master_socks} };

    $self->_drop_privs();    # after bind, before app load
    # Read after the drop: _verify_reuseport_bind may have turned it off.
    my $use_reuseport = $self->{_use_reuseport};

    my $gen = 0;
    my $current_pid;
    my $pending_pid;   # generation being started (not yet $current_pid)
    my $shutting_down = 0;
    my $startup_timeout = $self->{startup_timeout} // DEFAULT_STARTUP_TIMEOUT;

    # Declared here so the child can undef them: EV watchers survive fork.
    my ($hup, $quit, $int, $term, $reap, $usr2, $master_death);
    # Fed by a persistent USR2 watcher; a late USR2 with no handler kills the master.
    my $gen_ready = 0;
    # Restart backoff for a crashed generation.
    my ($gen_ready_at, $gen_restart_fails, $gen_restart_timer);

    # Only the master holds the write end, so a generation sees EOF when it dies.
    pipe(my $master_alive_r, my $master_alive_w)
        or croak "master liveness pipe: $!";

    my $fork_generation = sub {
        $gen++;
        my $pid = fork;
        croak "fork generation: $!" unless defined $pid;

        if ($pid == 0) {
            # === Generation child ===
            # An exception here would unwind into the caller's script in the child.
            eval {
            EV::default_loop()->loop_fork;
            # Drop the master's watchers before any loop iteration here.
            undef $hup; undef $quit; undef $int; undef $term; undef $reap;
            undef $usr2; undef $master_death; undef $gen_restart_timer;
            # Inherited daemonize pipe end; held, it hides a master death from the parent.
            if (my $rdy = delete $self->{_daemon_ready_fh}) { close $rdy }
            $quiet or warn "Feersum [$$]: gen $gen loading app\n";

            my $f = Feersum->endjinn;
            # Before use_socket, as in _prepare.
            if (defined $self->{accept_priority}) {
                $f->accept_priority($self->{accept_priority});
            }
            if ($use_reuseport) {
                # A reuseport socket nobody accepts on black-holes connections; close
                # the TCP ones.  UNIX listeners stay: workers inherit, not rebind.
                my $addrs = $self->{_listen_addrs} || [];
                my @keep;
                for my $i (0 .. $#socks) {
                    if (_is_unix_listen($addrs->[$i])) { $keep[$i] = $socks[$i]; next }
                    close($socks[$i])
                        or warn "Feersum [$$]: close inherited socket: $!\n"
                        if defined $socks[$i];
                }
                @socks = @keep;
                $self->{_master_socks} = [];
                $self->{_socks} = \@keep;
                ($self->{sock}) = grep { defined } @keep;
            }
            else {
                for my $sock (@socks) {
                    $f->use_socket($sock);
                }
                $self->{_socks} = \@socks;
                $self->{sock} = $socks[0];
            }

            $self->_apply_settings($f);

            my $app_file = rel2abs($self->{app_file});
            local ($@, $!) = (undef, undef);
            my $app = do $app_file;
            if ($@ || !$app || !_is_callable($app)) {
                warn "Feersum [$$]: gen $gen: failed to load $app_file: "
                    . ($@ || $! || "not a coderef") . "\n";
                POSIX::_exit(1);
            }

            $self->{endjinn} = $f;
            $self->assign_request_handler($app);

            my ($quit_w, $term_w, $int_w, $hup_w, $death_w);
            my $begin_gen_shutdown = sub {
                return if $self->{_shutdown};
                $self->{_shutdown} = 1;
                my $gt = $self->{graceful_timeout}
                      // $ENV{FEERSUM_GRACEFUL_TIMEOUT}
                      // DEATH_TIMER;
                if ($self->{_n_kids}) {
                    # Group QUIT includes self (guarded above); the reaper ends the loop.
                    # graceful_shutdown here would _exit(0) before the workers drain.
                    kill POSIX::SIGQUIT, -$$;
                    $gt += DEATH_TIMER_INCR;  # outlast the workers' deadline
                }
                else {
                    # A croak here (already draining a retirement) would skip arming $death_w.
                    my $ok = eval { $f->graceful_shutdown(sub { POSIX::_exit(0) }); 1 };
                    $self->{quiet} or $ok
                        or warn "Feersum [$$]: gen $gen: already draining, "
                              . "forcing exit in ${gt}s\n";
                }
                $death_w = EV::timer($gt, 0, sub {
                    # Exiting alone leaves orphaned workers holding the listen socket.
                    # The pid file is the master's; do not remove it here.
                    my @alive = grep { defined } @{ $self->{_kid_pids} || [] };
                    kill 'KILL', @alive if @alive;
                    POSIX::_exit(1);
                });
            };
            # systemd delivers TERM straight here; unhandled it would skip the drain.
            $quit_w = EV::signal 'QUIT', $begin_gen_shutdown;
            $term_w = EV::signal 'TERM', $begin_gen_shutdown;
            $int_w  = EV::signal 'INT',  $begin_gen_shutdown;
            # A group or mis-aimed HUP would otherwise kill the generation.
            $hup_w  = EV::signal 'HUP', sub {
                $quiet or warn "Feersum [$$]: gen $gen ignoring SIGHUP "
                             . "(reload is the master's job)\n";
            };

            # Close our write-end copy so only the master holds one.  The watcher
            # clears itself: a level-triggered EV::io on a dead pipe busy-spins.
            close $master_alive_w;
            my $master_gone_watch;
            $master_gone_watch = EV::io($master_alive_r, EV::READ, sub {
                $master_gone_watch = undef;
                $quiet or warn "Feersum [$$]: master is gone, draining\n";
                $begin_gen_shutdown->();
            });

            if ($self->{pre_fork}) {
                $f->set_multiprocess(1);
                # The master's post-privdrop decision, not a recompute from config.
                $self->{_use_reuseport} = $use_reuseport;
                # setsid() returns -1 (true) on failure; EPERM means already a session leader.
                POSIX::setsid() == SYSCALL_ERROR and $! != POSIX::EPERM()
                    and warn "Feersum [$$]: setsid failed: $!\n";
                $self->{_kids} = [];
                $self->{_kid_pids} = [];   # inherited: another generation's
                $self->{_n_kids} = 0;
                pipe(my $wready_r, my $wready_w)
                    or croak "worker readiness pipe: $!";
                $self->{_worker_ready_pipe} = [$wready_r, $wready_w];
                $self->_fork_another($_) for (1 .. $self->{pre_fork});
                $f->unlisten();  # parent of workers doesn't accept
                # Gate on live workers: a failed reload must not retire the old generation.
                my $up = $self->_wait_for_workers_ready(
                    $self->{pre_fork}, $startup_timeout);
                if ($up < $self->{pre_fork} && !$self->{_shutdown}) {
                    warn "Feersum [$$]: gen $gen: only $up of "
                        . "$self->{pre_fork} workers came up; failing\n";
                    POSIX::_exit(1);
                }
            }

            if (!$self->{pre_fork}) {
                if (my $cb = $self->{after_fork}) {
                    unless (eval { $cb->(); 1 }) {
                        warn "Feersum [$$]: after_fork failed: $@";
                        POSIX::_exit(1);
                    }
                }
                $self->_set_max_requests_per_worker($f);
            }

            kill 'USR2', getppid() unless $self->{_shutdown};

            $quiet or warn "Feersum [$$]: gen $gen ready"
                . ($self->{pre_fork} ? " ($self->{pre_fork} workers)" : "") . "\n";
            EV::run;
            1;
            } or do {
                my $err = $@ || 'unknown error';
                warn "Feersum [$$]: gen $gen failed to start: $err";
                POSIX::_exit(1);
            };
            POSIX::_exit(0);
        }

        return $pid;
    };

    my $begin_shutdown = sub {
        my ($why) = @_;
        return if $shutting_down;
        $shutting_down = 1;
        $gen_restart_timer = undef;
        $quiet or warn "Feersum [$$]: master $why\n";
        kill 'QUIT', $current_pid if $current_pid;
        kill 'QUIT', $pending_pid if $pending_pid;
        # With nothing to reap the reap watcher never breaks the loop; break here.
        EV::break unless $current_pid || $pending_pid;

        # Backstop for a generation wedged in app code, whose own deadline never
        # runs; set later than that deadline so the graceful path goes first.
        my $gt = ($self->{graceful_timeout}
               // $ENV{FEERSUM_GRACEFUL_TIMEOUT}
               // DEATH_TIMER) + 2 * DEATH_TIMER_INCR;
        $master_death = EV::timer $gt, 0, sub {
            $quiet or warn "Feersum [$$]: master shutdown timed out, forcing\n";
            for my $p (grep { $_ } $current_pid, $pending_pid) {
                kill 'KILL', $p;
                # A pre-fork generation setsid()s; its workers are reachable only by group.
                kill 'KILL', -$p;
            }
            $self->_remove_pid_file;
            POSIX::_exit(1);
        };
    };

    # EV swallows a croak inside a watcher callback; return undef instead.
    my $try_fork_generation = sub {
        my $pid = eval { $fork_generation->() };
        return $pid if $pid;
        my $why = $@ || $!;
        $why =~ s/\s+\z//;
        warn "Feersum [$$]: could not fork a generation: $why\n";
        return;
    };

    # Before generation 1 forks, or a QUIT during startup kills the master.
    $hup = EV::signal 'HUP', sub {
        return if $shutting_down || $pending_pid;  # debounce rapid HUPs
        $quiet or warn "Feersum [$$]: HUP - spawning gen " . ($gen + 1) . "\n";
        $gen_restart_timer = undef;
        $gen_restart_fails = 0;

        my $old_pid = $current_pid;
        # The old generation is still serving, so a failed reload is survivable.
        $pending_pid = $try_fork_generation->() or return;

        if (_wait_for_ready($pending_pid, $quiet, $gen, \$gen_ready,
                            \$shutting_down, $startup_timeout)) {
            $quiet or warn "Feersum [$$]: gen $gen ready (pid $pending_pid), retiring old (pid "
                . (defined $old_pid ? $old_pid : q{none}) . ")\n";
            # $current_pid may have been reaped and reused during the reload.
            my $retire = ($current_pid && $current_pid == $old_pid) ? $old_pid : undef;
            $current_pid = $pending_pid;
            $pending_pid = undef;
            kill 'QUIT', $retire if $retire;
        } else {
            kill 'KILL', $pending_pid if kill(0, $pending_pid);
            waitpid($pending_pid, 0);
            $pending_pid = undef;
            # The reaper may have cleared $current_pid mid-reload without restarting.
            if ($current_pid) {
                warn "Feersum [$$]: gen $gen failed, keeping old (pid $current_pid)\n";
            }
            elsif ($shutting_down) {
                EV::break;
            }
            else {
                warn "Feersum [$$]: gen $gen failed and the running generation "
                    . "died during the reload - starting a replacement\n";
                # Nothing is serving, so a failed fork is terminal.
                $pending_pid = $try_fork_generation->();
                if (!$pending_pid) {
                    EV::break;
                }
                elsif (_wait_for_ready($pending_pid, $quiet, $gen, \$gen_ready,
                                    \$shutting_down, $startup_timeout)) {
                    $current_pid = $pending_pid;
                } else {
                    warn "Feersum [$$]: replacement generation also failed, "
                        . "giving up\n";
                    kill 'KILL', $pending_pid if kill(0, $pending_pid);
                    waitpid($pending_pid, 0);
                    EV::break;
                }
                $pending_pid = undef;
            }
        }
    };

    $quit = EV::signal 'QUIT', sub { $begin_shutdown->('shutting down') };
    $int  = EV::signal 'INT',  sub { $begin_shutdown->('interrupted') };
    # systemctl stop sends TERM; unhandled it orphans the generation.
    $term = EV::signal 'TERM', sub { $begin_shutdown->('terminated') };
    $usr2 = EV::signal 'USR2', sub { $gen_ready = 1 };

    my $restart_generation = sub {
        return if $shutting_down || $pending_pid;
        warn "Feersum [$$]: active generation died, restarting\n" unless $quiet;
        $pending_pid = $try_fork_generation->();
        if (!$pending_pid) {
            EV::break;
        }
        elsif (_wait_for_ready($pending_pid, $quiet, $gen, \$gen_ready,
                               \$shutting_down, $startup_timeout)) {
            $current_pid  = $pending_pid;
            $gen_ready_at = EV::time();
        } else {
            warn "Feersum [$$]: replacement generation also failed, giving up\n"
                unless $quiet;
            kill 'KILL', $pending_pid if kill(0, $pending_pid);
            waitpid($pending_pid, 0);
            EV::break;
        }
        $pending_pid = undef;
    };

    $reap = EV::child 0, 0, sub {
        my $kid = $_[0]->rpid;
        my $rstatus = $_[0]->rstatus;
        my $how = ($rstatus & WSTATUS_SIGNAL_MASK)
            ? "killed by signal " . ($rstatus & WSTATUS_SIGNAL_MASK)
            : "exited (" . ($rstatus >> WSTATUS_EXIT_SHIFT) . ")";
        $quiet or warn "Feersum [$$]: child $kid $how\n";
        # _wait_for_ready owns the pending generation.
        return if $pending_pid && $kid == $pending_pid;
        if ($current_pid && $kid == $current_pid) {
            $current_pid = undef;
            EV::break if $shutting_down;
            unless ($shutting_down || $pending_pid) {
                my $lifetime = defined $gen_ready_at
                    ? EV::time() - $gen_ready_at : undef;
                if (defined $lifetime && $lifetime < RESPAWN_INSTANT_DEATH) {
                    my $n = ++$gen_restart_fails;
                    my $delay = $n > RESPAWN_MAX_FAILS ? RESPAWN_BACKOFF_MAX
                              : RESPAWN_BACKOFF_BASE * (2 ** ($n - 1));
                    $delay = RESPAWN_BACKOFF_MAX if $delay > RESPAWN_BACKOFF_MAX;
                    warn sprintf "Feersum [%d]: active generation died after "
                        . "%.2fs, restarting in %gs (failure %d)\n",
                        $$, $lifetime, $delay, $n unless $quiet;
                    $gen_restart_timer = EV::timer($delay, 0, sub {
                        $gen_restart_timer = undef;
                        $restart_generation->();
                    });
                }
                else {
                    $gen_restart_fails = 0;
                    $restart_generation->();
                }
            }
        }
    };

    $pending_pid = $fork_generation->();

    # Held open, the master's copies black-hole a share of connections and,
    # root-owned, keep privdropped workers out of the reuseport group.
    if ($use_reuseport) {
        # UNIX listeners stay: workers inherit them rather than rebinding.
        my $addrs = $self->{_listen_addrs} || [];
        my @keep;
        for my $i (0 .. $#socks) {
            if (_is_unix_listen($addrs->[$i])) { $keep[$i] = $socks[$i]; next }
            close($socks[$i]) or warn "Feersum [$$]: close master socket: $!\n"
                if defined $socks[$i];
        }
        @socks = @keep;
        $self->{_master_socks} = \@keep;
    }

    unless (_wait_for_ready($pending_pid, $quiet, $gen, \$gen_ready,
                            \$shutting_down, $startup_timeout)) {
        kill 'KILL', $pending_pid if kill(0, $pending_pid);
        waitpid($pending_pid, 0);
        $pending_pid = undef;
        # A QUIT/INT/TERM during startup is a shutdown request, not a failure.
        return if $shutting_down;
        croak "first generation failed to start";
    }
    $current_pid  = $pending_pid;
    $pending_pid  = undef;
    $gen_ready_at = EV::time();

    # Generation 1 is serving: only now is a daemonized start a success.
    $self->_daemon_ready;

    $quiet or warn "Feersum [$$]: master ready (gen $gen, pid $current_pid)\n";

    EV::run;
    # @socks is sparse under reuseport (indices line up with _listen_addrs).
    for my $sock (grep { defined } @socks) { close($sock) }
    waitpid(WAIT_ANY_PID, POSIX::WNOHANG()) for 1 .. FINAL_REAP_ATTEMPTS;
    $quiet or warn "Feersum [$$]: master done\n";
    return;
}

# RUN_ONCE loop so an EV::break cannot propagate to the outer EV::run.
sub _wait_for_ready { ## no critic (ProhibitManyArgs)
    my ($pid, $quiet, $gen, $ready_ref, $shutdown_ref, $timeout) = @_;
    $timeout //= DEFAULT_STARTUP_TIMEOUT;
    # Clear first: a stale USR2 from a timed-out generation must not count.
    $$ready_ref = 0;
    my ($done, $died) = (0, 0);
    my $fail = EV::child $pid, 0, sub {
        warn "Feersum [$$]: gen $gen (pid $pid) died during startup\n";
        $done = 1; $died = 1;
    };
    my $to = EV::timer($timeout, 0, sub {
        warn "Feersum [$$]: gen $gen startup timeout\n";
        $done = 1;
    });
    EV::run(EV::RUN_ONCE)
        until $done || $$ready_ref || ($shutdown_ref && $$shutdown_ref);
    # Ready then dead in one batch is dead: adopting a reaped pid wedges the master.
    return ($$ready_ref && !$died) ? 1 : 0;
}

# The reaper runs in this loop, so an early death can respawn and still report.
sub _wait_for_workers_ready {
    my ($self, $count, $timeout) = @_;
    my $pipe = $self->{_worker_ready_pipe} or return $count;
    $timeout //= DEFAULT_STARTUP_TIMEOUT;
    my $ready = 0;
    my $rfh = $pipe->[0];
    my $expired = 0;
    # Our write end stays open for respawns, so gate on count and deadline, not EOF.
    my $io = EV::io($rfh, EV::READ, sub {
        my $n = sysread($rfh, my $buf, WORKER_READY_BUFSZ);
        $ready += $n if $n;
    });
    my $to = EV::timer($timeout, 0, sub { $expired = 1 });
    while (!$expired && $ready < $count && !$self->{_shutdown}) {
        EV::run(EV::RUN_ONCE);
    }
    undef $io; undef $to;
    delete $self->{_worker_ready_pipe};  # later respawns must not write here
    return $ready;
}

sub _apply_settings {
    my ($self, $f) = @_;
    $self->_apply_simple_settings($f, 0);  # preserve $self for re-use

    if (my $tls = $self->{tls}) {
        if ($f->has_tls()) {
            # 0 under reuseport: each worker applies TLS to the socket it binds.
            my $n = scalar @{$self->{_master_socks} || $self->{_socks} || []};
            $self->_apply_tls_to_listeners($f, $n, $tls, $self->{sni});
            $self->{_tls_config} = $tls;  # for reuseport workers
        } else {
            warn "Feersum [$$]: tls configured but TLS not compiled in"
                . " - aborting generation\n";
            POSIX::_exit(1);
        }
    }
    return;
}

# Close our write-end copy so only the parent holds one; drain on its EOF.
sub _watch_for_parent_death {
    my $self = shift;
    my $pipe = $self->{_parent_death_pipe} or return;
    close $pipe->[1];
    my $s = $self;
    weaken $s;
    $self->{_parent_death_w} = EV::io($pipe->[0], EV::READ, sub {
        return unless $s;
        $s->{quiet} or warn "Feersum [$$]: parent is gone, draining\n";
        $s->{_parent_death_w} = undef;
        $s->quit;
    });
    return;
}

sub _fork_another { ## no critic (ProhibitExcessComplexity)
    my ($self, $slot) = @_;

    # Only the parent keeps the write end, so a worker sees EOF however it died.
    $self->{_parent_death_pipe} ||= do {
        pipe(my $r, my $w) or croak "worker death pipe: $!";
        [$r, $w];
    };

    my $pid = fork;
    croak "failed to fork: $!" unless defined $pid;
    unless ($pid) {
        EV::default_loop()->loop_fork;
        $self->{quiet} or warn "Feersum [$$]: starting\n";
        delete $self->{_kids};
        delete $self->{_kid_pids};  # the parent's workers, not ours to signal
        delete $self->{pre_fork};
        # Inherited daemonize pipe end; held, it hides a master death from the parent.
        if (my $rdy = delete $self->{_daemon_ready_fh}) { close $rdy }
        $self->_watch_for_parent_death;
        # EV timers survive fork: an inherited respawn timer would fork grandchildren.
        delete $self->{_respawn_timers};
        delete $self->{_kid_started};
        delete $self->{_respawn_fails};
        $self->{_n_kids} = 0;

        if ($self->{_use_reuseport}) {
            my @addrs = @{$self->{_listen_addrs}};
            my @old   = @{$self->{_socks} || []};
            $self->{endjinn}->unlisten();
            my @new_socks;
            eval {
                for my $i (0 .. $#addrs) {
                    my $listen = $addrs[$i];
                    # Rebinding a UNIX path would unlink the previous worker's socket.
                    if (_is_unix_listen($listen)) {
                        push @new_socks, $old[$i];
                        $self->{endjinn}->use_socket($old[$i]);
                        next;
                    }
                    if (defined $old[$i]) {
                        close($old[$i])
                            or die "close parent socket in child: $!\n";
                    }
                    my $sock = $self->_create_socket($listen, 1);
                    push @new_socks, $sock;
                    $self->{endjinn}->use_socket($sock);
                }
                1;
            } or do {
                warn "Feersum [$$]: child socket creation failed: $@";
                POSIX::_exit(1);
            };
            $self->{sock} = $new_socks[0];
            $self->{_socks} = \@new_socks;

            # An unguarded croak here unwinds the child into the supervisor's frames.
            if (my $tls = $self->{_tls_config}) {
                unless (eval {
                    $self->_apply_tls_to_listeners(
                        $self->{endjinn}, scalar(@new_socks), $tls, $self->{sni});
                    1;
                }) {
                    warn "Feersum [$$]: worker TLS setup failed: $@";
                    POSIX::_exit(1);
                }
            }

            # An owned listener's accept queue dies with it; a shared one passes to a sibling.
            $self->{endjinn}->set_drain_accept_queue(1);
        }

        if (my $loader = $self->{_app_loader}) {
            unless (eval { $loader->(); 1 }) {
                warn "Feersum [$$]: worker app load failed: $@";
                POSIX::_exit(1);
            }
        }

        # On a respawn this runs inside an EV callback, which would swallow a die.
        if (my $cb = $self->{after_fork}) {
            unless (eval { $cb->(); 1 }) {
                warn "Feersum [$$]: after_fork failed: $@";
                POSIX::_exit(1);
            }
        }

        unless (eval { $self->_set_max_requests_per_worker($self->{endjinn}); 1 }) {
            warn "Feersum [$$]: worker max-requests setup failed: $@";
            POSIX::_exit(1);
        }

        # One readiness byte each; the parent may already have closed its end.
        if (my $rp = delete $self->{_worker_ready_pipe}) {
            local $SIG{PIPE} = 'IGNORE';
            syswrite $rp->[1], 'R';
            close $rp->[1];
            close $rp->[0];
        }

        eval { EV::run; }; ## no critic (RequireCheckingReturnValueOfEval)
        carp $@ if $@;
        POSIX::_exit($@ ? 1 : 0);  # _exit avoids running parent's END blocks
    }

    weaken $self;  # prevent circular ref with watcher callback
    $self->{_n_kids}++;
    $self->{_kid_started}[$slot] = EV::time();  # for respawn backoff
    $self->{_kid_pids}[$slot] = $pid;           # for the force-exit backstop
    $self->{_kids}[$slot] = EV::child $pid, 0, sub {
        my $w = shift;
        return unless $self;
        $self->{quiet} or warn "Feersum [$$]: child $pid exited ".
            "with rstatus ".$w->rstatus."\n";
        $self->{_n_kids}--;
        undef $self->{_kid_pids}[$slot];  # reaped; never signal a reused pid
        if ($self->{_shutdown}) {
            unless ($self->{_n_kids}) {
                $self->{_death} = undef;
                EV::break(EV::BREAK_ALL());
            }
            return;
        }
        my $rstatus  = $w->rstatus;
        my $retired  = ($rstatus & WSTATUS_SIGNAL_MASK) == 0
                    && ($rstatus >> WSTATUS_EXIT_SHIFT) == EXIT_RETIRED;
        my $started  = $self->{_kid_started}[$slot];
        my $lifetime = defined $started ? EV::time() - $started : undef;
        if (!$retired && defined $lifetime && $lifetime < RESPAWN_INSTANT_DEATH) {
            my $n = ++$self->{_respawn_fails}[$slot];
            my $delay = $n > RESPAWN_MAX_FAILS
                ? RESPAWN_BACKOFF_MAX
                : RESPAWN_BACKOFF_BASE * (2 ** ($n - 1));
            $delay = RESPAWN_BACKOFF_MAX if $delay > RESPAWN_BACKOFF_MAX;
            warn "Feersum [$$]: worker slot $slot has died immediately $n "
                . "times, still retrying every ${delay}s "
                . "(check the app and after_fork)\n"
                if $n == RESPAWN_MAX_FAILS + 1;
            warn sprintf "Feersum [%d]: worker slot %d died after %.2fs, "
                . "respawning in %gs (failure %d)\n", $$, $slot, $lifetime,
                $delay, $n;
            $self->{_respawn_timers}[$slot] = EV::timer($delay, 0, sub {
                return unless $self;
                return if $self->{_shutdown};
                $self->{_respawn_timers}[$slot] = undef;
                $self->_respawn_worker($slot);
            });
            return;
        }
        $self->{_respawn_fails}[$slot] = 0;
        $self->_respawn_worker($slot);
    };
    return;
}

# Without reuseport the parent must be listening across the fork.
sub _respawn_worker {
    my ($self, $slot) = @_;
    unless ($self->{_use_reuseport}) {
        my $feersum = $self->{endjinn};
        my @socks = @{$self->{_socks} || [$self->{sock}]};
        my $all_valid = 1;
        for my $sock (@socks) {
            unless (defined fileno $sock) {
                $all_valid = 0;
                last;
            }
        }
        if ($all_valid) {
            # unlisten() dropped the TLS context, so rebuild the listeners fully.
            # Guarded: EV would swallow a croak and leave the supervisor listening.
            my $forked = eval {
                for my $sock (@socks) {
                    $feersum->use_socket($sock);
                }
                if (my $tls = $self->{_tls_config}) {
                    $self->_apply_tls_to_listeners(
                        $feersum, scalar(@socks), $tls, $self->{sni});
                }
                $self->_fork_another($slot);
                1;
            };
            my $err = $@;
            $feersum->unlisten;
            $self->_retry_respawn($slot, $err) unless $forked;
        } else {
            $self->_retry_respawn($slot, 'listen socket has no fileno');
        }
    }
    else {
        my $forked = eval { $self->_fork_another($slot); 1 };
        $self->_retry_respawn($slot, $@) unless $forked;
    }
    return;
}

# EV swallows a fork failure in a callback; retry or the slot is stranded for good.
sub _retry_respawn {
    my ($self, $slot, $err) = @_;
    return if $self->{_shutdown};
    my $n = ++$self->{_respawn_fails}[$slot];
    my $delay = $n > RESPAWN_MAX_FAILS
        ? RESPAWN_BACKOFF_MAX
        : RESPAWN_BACKOFF_BASE * (2 ** ($n - 1));
    $delay = RESPAWN_BACKOFF_MAX if $delay > RESPAWN_BACKOFF_MAX;
    my $msg = defined $err ? $err : 'unknown error';
    $msg =~ s/\s+\z//;
    warn sprintf "Feersum [%d]: could not fork worker slot %d (%s), "
        . "retrying in %gs (failure %d)\n", $$, $slot, $msg, $delay, $n;
    $self->{_respawn_timers}[$slot] = EV::timer($delay, 0, sub {
        return unless $self;
        return if $self->{_shutdown};
        $self->{_respawn_timers}[$slot] = undef;
        $self->_respawn_worker($slot);
    });
    return;
}

sub _start_pre_fork {
    my $self = shift;

    $self->{endjinn}->set_multiprocess(1);

    # setsid() returns -1 (true) on failure; EPERM means already a session leader.
    POSIX::setsid() == SYSCALL_ERROR and $! != POSIX::EPERM()
        and croak "setsid() failed: $!";

    $self->{_kids} = [];
    $self->{_kid_pids} = [];   # inherited entries belong to another generation
    $self->{_n_kids} = 0;
    # Close before forking: a root-owned member locks privdropped workers out of the group.
    if ($self->{_use_reuseport}) {
        $self->{endjinn}->unlisten();
        # UNIX listeners stay: workers inherit them rather than rebinding.
        my $addrs = $self->{_listen_addrs} || [];
        my $socks = $self->{_socks} || [];
        my @keep;
        for my $i (0 .. $#$socks) {
            if (_is_unix_listen($addrs->[$i])) { $keep[$i] = $socks->[$i]; next }
            close($socks->[$i]) or warn "close parent socket before fork: $!";
        }
        $self->{_socks} = \@keep;
        ($self->{sock}) = grep { defined } @keep;
    }

    # Under daemonize, gate the ready token on the workers actually coming up.
    my $gate = $self->{daemonize};
    if ($gate) {
        pipe(my $wready_r, my $wready_w)
            or croak "worker readiness pipe: $!";
        $self->{_worker_ready_pipe} = [$wready_r, $wready_w];
    }

    $self->_fork_another($_) for (1 .. $self->{pre_fork});

    $self->{endjinn}->unlisten() unless $self->{_use_reuseport};

    return 1 unless $gate;
    return $self->_wait_for_workers_ready(
        $self->{pre_fork}, $self->{startup_timeout}) >= $self->{pre_fork};
}

# False only on EOF before the token; a timeout counts as success.
sub _await_daemon_ready {
    my ($self, $rdy_r) = @_;
    my $rin = '';
    vec($rin, fileno($rdy_r), 1) = 1;
    my $wait = $self->{startup_timeout} // DEFAULT_STARTUP_TIMEOUT;
    my $deadline = EV::time() + $wait;
    my $nready = 0;
    # A SIGCHLD EINTR would read as a timeout, i.e. success; resume instead.
    while (1) {
        my $remaining = $deadline - EV::time();
        last if $remaining <= 0;
        $nready = select(my $rout = $rin, undef, undef, $remaining);
        last if !defined $nready || $nready >= 0 || $! != POSIX::EINTR();
    }
    return 1 if !$nready || $nready < 1;
    my $n = sysread($rdy_r, my $tok, READY_TOKEN_SIZE);
    return (defined $n && $n == 0) ? 0 : 1;
}

# Idempotent; the parent reads EOF without a token as a failed start.
sub _daemon_ready {
    my $self = shift;
    my $fh = delete $self->{_daemon_ready_fh} or return;
    # The parent may have timed out and closed its end; a bare write takes SIGPIPE.
    local $SIG{PIPE} = 'IGNORE';
    syswrite $fh, 'R';
    close $fh;
    return;
}

# Records whether the probe created the file; cleanup must not remove a live one.
sub _probe_pid_file_writable {
    my $self = shift;
    my $file = $self->{pid_file} or return;
    $self->{_pid_file_probed} = !-e $file;
    open my $probe, '>>', $file or croak "Cannot write pid_file '$file': $!";
    close $probe or croak "Cannot write pid_file '$file': $!";
    return;
}

# A zero-byte pid file left behind reads to a health check as a running server.
sub _discard_probed_pid_file {
    my $self = shift;
    my $file = $self->{_pid_file_probed} ? $self->{pid_file} : undef;
    unlink $file if $file && -z $file;
    return;
}

sub _daemonize_and_write_pid {
    my $self = shift;

    if ($self->{daemonize}) {
        # Before forking, or the daemon is already serving when the parent croaks.
        $self->_probe_pid_file_writable;
        pipe(my $rdy_r, my $rdy_w) or croak "daemonize pipe: $!";
        my $pid = fork;
        croak "daemonize fork: $!" unless defined $pid;
        if ($pid) {
            close $rdy_w;
            my $ready = $self->_await_daemon_ready($rdy_r);
            close $rdy_r;
            unless ($ready) {
                waitpid $pid, 0;
                $self->_discard_probed_pid_file;
                warn "Feersum: startup failed, see the log for the reason\n"
                    unless $self->{quiet};
                POSIX::_exit(1);
            }
            if (my $file = $self->{pid_file}) {
                open my $fh, '>', $file or croak "Cannot write pid_file '$file': $!";
                print {$fh} "$pid\n";
                # a failed close truncates the pid file
                close $fh or croak "Cannot write pid_file '$file': $!";
            }
            POSIX::_exit(0);
        }
        close $rdy_r;
        $self->{_daemon_ready_fh} = $rdy_w;
        POSIX::setsid();
        open STDIN,  '<', '/dev/null' or croak "redirect stdin: $!";
        open STDOUT, '>', '/dev/null' or croak "redirect stdout: $!";
        open STDERR, '>', '/dev/null' or croak "redirect stderr: $!"
            unless $ENV{FEERSUM_DEBUG};
    } elsif (my $file = $self->{pid_file}) {
        open my $fh, '>', $file or croak "Cannot write pid_file '$file': $!";
        print {$fh} "$$\n";
        close $fh or croak "Cannot write pid_file '$file': $!";
    }
    return;
}

sub _drop_privs { ## no critic (ProhibitExcessComplexity)
    my $self = shift;

    # The user's primary group is the default when no group is configured.
    my ($uid, $gid);
    if (my $user = $self->{user}) {
        (undef, undef, $uid, my $pw_gid) = getpwnam($user);
        croak "Unknown user '$user'" unless defined $uid;
        $gid = $pw_gid;
    }
    if (my $group = $self->{group}) {
        $gid = getgrnam($group);
        croak "Unknown group '$group'" unless defined $gid;
    }

    if (defined $gid) {
        # Assigning $) also clears supplemental groups (setgroups), which needs
        # root; a non-root start has none to shed and would only EPERM.
        my $root = ($> == 0);
        if ($root) {
            # $) hides the syscall results; errno is the only signal, so clear it first.
            $! = 0;
            $) = "$gid $gid";
            croak "setgroups/setegid($gid): $!" if $!;
        }
        POSIX::setgid($gid) or croak "setgid($gid): $!";
        # As root $) = "g g" set setgroups([g]), so every token of $( must be $gid;
        # non-root could only set the real GID, the first token.
        my @rg = split ' ', $(;
        croak "setgid($gid) verification failed: real GID list is @rg"
            if !@rg || ($root ? (any { $_ != $gid } @rg) : $rg[0] != $gid);
    }
    if (defined $uid) {
        POSIX::setuid($uid) or croak "setuid($uid): $!";
        croak "setuid($uid) verification failed: \$<=$<, \$>=$>"
            unless $< == $uid && $> == $uid;
    }
    if (defined $uid || defined $gid) {
        $self->_verify_reuseport_bind;
        # Warn now: at shutdown stderr may already be closed.
        if (my $file = $self->{pid_file}) {
            my ($dir) = $file =~ m{^(.*)/[^/]+\z};
            $dir = q{.} unless defined $dir && length $dir;
            warn "Feersum [$$]: pid_file '$file' cannot be removed at shutdown: "
               . "'$dir' is not writable after dropping privileges\n"
                unless -w $dir;
        }
    }
    return;
}

# Probe the post-drop rebind while the inherited-socket fallback is still open.
sub _verify_reuseport_bind {
    my $self = shift;
    return unless $self->{_use_reuseport};

    # EADDRINUSE is a pass: the kernel checks bind permission before the address
    # conflict, and we still hold the address.  Built so it matches any locale.
    my $in_use = do { local $! = POSIX::EADDRINUSE(); qq{$!} };

    for my $listen (@{ $self->{_listen_addrs} || [] }) {
        next if _is_unix_listen($listen);   # inherited, never rebound
        my $probe = eval { $self->_create_socket($listen, 1, 1) };
        if ($probe) { close $probe; next }
        my $why = $@ || "unknown error";
        $why =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
        next if index($why, $in_use) >= 0;
        warn "Feersum [$$]: cannot rebind '$listen' after dropping privileges "
           . "($why); disabling reuseport - workers will share the inherited "
           . "listen socket instead\n";
        $self->{_use_reuseport} = 0;
        last;
    }
    return;
}

sub quit {
    my $self = shift;
    return if $self->{_shutdown};

    $self->{_shutdown} = 1;
    $self->{quiet} or warn "Feersum [$$]: shutting down...\n";
    my $death = $self->{graceful_timeout}
             // $ENV{FEERSUM_GRACEFUL_TIMEOUT}
             // DEATH_TIMER;

    if ($self->{_n_kids}) {
        # Group QUIT includes self; guarded by _shutdown above.
        kill POSIX::SIGQUIT, -$$;
        $death += DEATH_TIMER_INCR;
    }
    else {
        # _exit skips END and DESTROY, so remove the pid file here.  Guarded: a
        # croak (already draining a retirement) would skip arming the backstop.
        my $ok = eval {
            $self->{endjinn}->graceful_shutdown(sub {
                $self->_remove_pid_file;
                POSIX::_exit(0);
            });
            1;
        };
        $self->{quiet} or $ok
            or warn "Feersum [$$]: already draining, forcing exit in ${death}s\n";
    }

    # Backstop; exiting alone leaves orphaned workers holding the listen socket.
    my $s = $self;
    weaken $s;   # the watcher is stored on $self; a strong ref here leaks it
    $self->{_death} = EV::timer $death, 0, sub {
        return unless $s;
        $s->_remove_pid_file;
        my @alive = grep { defined } @{ $s->{_kid_pids} || [] };
        kill 'KILL', @alive if @alive;
        POSIX::_exit(1);
    };
    return;
}

1;
__END__

=head1 NAME

Feersum::Runner - feersum script core

=head1 SYNOPSIS

    use Feersum::Runner;
    my $runner = Feersum::Runner->new(
        listen => 'localhost:5000',
        pre_fork => 0,
        quiet => 1,
        app_file => 'app.feersum',
    );
    $runner->run($feersum_app);

=head1 DESCRIPTION

Process manager for Feersum.  Handles listen sockets, pre-forking,
hot restart, TLS, daemonization, and graceful shutdown.

=head1 METHODS

=over 4

=item C<< Feersum::Runner->new(%params) >>

Returns a Feersum::Runner singleton.  If called again while not running, the
previous instance is replaced with a new one using the provided params.

=over 8

=item listen

Listen address as an arrayref of one or more address strings, e.g.
C<< listen => ['localhost:5000'] >>, or a plain string for a single address.
Formats: C<host:port> for IPv4, C<[host]:port> for IPv6 (needs Perl 5.14+
with Socket IPv6 support).  A bare (unbracketed) IPv6 address whose tail looks
like a port is rejected as ambiguous.

An entry beginning with C</> or C<.> is bound as a UNIX-domain socket, created
world-accessible (mode C<0777>); restrict access through the directory's
permissions.

Alternatively, use C<host> and C<port>.

=item pre_fork

Fork this many worker processes.  The app is loaded once in the parent and
inherited copy-on-write unless C<< preload_app => 0 >>.

=item preload_app

Whether the app is loaded before forking workers (default: true).  When true,
workers inherit the loaded app copy-on-write; use C<after_fork> to reconnect
per-process resources.  When false, each worker loads C<app_file> itself
after the fork; that needs C<app_file> and no app coderef, since a coderef
(C<app>, or passed to C<run()>) is shared as compiled.  Ignored under
C<hot_restart>, where each generation loads the app once and forks
copy-on-write.

=item hot_restart

Generation-based hot restart.  Requires C<app_file>.  The entry process
becomes a supervisor; on C<SIGHUP> it forks a new generation that re-runs the
app file from scratch and, once that generation is ready, retires the old one
via C<SIGQUIT>.  A generation that fails to start is discarded and the old
one keeps serving.

Works with C<pre_fork> (each generation forks its own workers) and with
C<tls>/C<h2>.  Modules already loaded before C<run()> are inherited via fork
and B<not> reloaded; restart the supervisor to refresh those.

Under C<plackup> the C<.psgi> path must also be given to plackup itself;
C<app_file> only names what each generation re-runs:

    plackup -s Feersum --app-file=app.psgi --hot-restart=1 --pre-fork=4 app.psgi
    kill -HUP <master-pid>

=item backlog

Listen socket backlog (default: C<SOMAXCONN>).  Raise it if the kernel's
C<somaxconn> is tuned above the compile-time constant; the kernel clamps to
its own maximum.

=item keepalive

Enable/disable http keepalive requests.

=item reverse_proxy

Trust C<X-Forwarded-For> and C<X-Forwarded-Proto> from an upstream proxy:
C<REMOTE_ADDR> becomes the first forwarded IP and C<psgi.url_scheme> follows
C<X-Forwarded-Proto>.  The native C<< $req->client_address >> and
C<< $req->url_scheme >> honour this too.  Only enable behind a trusted proxy.

=item proxy_protocol

Expect a PROXY protocol header (v1 or v2, auto-detected) at the start of every
connection and take C<REMOTE_ADDR>/C<REMOTE_PORT> from it; v1 C<UNKNOWN>, v2
C<LOCAL> and non-INET families keep the socket address.  Independent of
C<reverse_proxy>, which is applied on top.  Only enable when every connection
comes through such a proxy: a connection without a valid header is rejected
with HTTP 400.  HAProxy example:

    backend feersum_backend
        mode http
        server feersum 127.0.0.1:5000 send-proxy-v2

=item psgix_io

Enable the C<psgix.io> PSGI extension (default: enabled).  Disable it to skip
the per-request overhead if the app never needs the raw socket.

=item read_timeout

Read/keepalive timeout in seconds (default: 5).  Must be positive.

=item header_timeout

Seconds allowed to receive complete request headers (default: 10; 0 disables).

=item write_timeout

Seconds allowed for a stalled response write before the connection is closed
(default: 0, disabled).

=item max_connection_reqs

Set max requests per connection in case of keepalive - 0(default) for unlimited.

=item max_accept_per_loop

Connections accepted per event loop cycle (default: 64).  Lower values spread
load more evenly across prefork workers sharing a listen socket.

=item max_connections

Maximum concurrent connections (default: 10000; 0 disables).  At the limit the
oldest idle keep-alive connection is closed to make room; if none is idle, the
new connection is closed and accepting pauses on that listener until a slot
frees.

=item max_read_buf

Maximum read buffer per connection (default: 64 MiB), bounding header parsing
and chunked body reception.

=item max_body_len

Maximum request body size (default: 64 MiB), applied to C<Content-Length> and
to the cumulative chunked body.

=item max_uri_len

Set max request URI length (default: 8192).

=item wbuf_low_water

Set write buffer low-water mark in bytes (default: 0).  Used with C<poll_cb()>
on streaming responses: the callback fires when the buffer drains to or below
this threshold.

=item read_priority

=item write_priority

=item accept_priority

Set libev I/O watcher priorities for read, write, and accept operations.
Valid range is -2 (lowest) to +2 (highest), default is 0.

=item tls

Enable TLS 1.3 on all listeners. Pass a hash reference with C<cert_file>
and C<key_file> paths:

    Feersum::Runner->new(
        listen => ['0.0.0.0:8443'],
        tls    => { cert_file => 'server.crt', key_file => 'server.key' },
        app    => $app,
    )->run;

Requires Feersum built with TLS support.  HTTP/2 needs C<< h2 => 1 >> as well.

=item tls_cert_file

=item tls_key_file

Flat alternatives to the C<tls> hash, useful with plackup's pass-through
options:

    plackup -s Feersum --tls-cert-file=server.crt --tls-key-file=server.key

Both must be specified together. If a C<tls> hash is also provided, it takes
precedence and these are ignored.

=item h2

Negotiate HTTP/2 via ALPN on TLS listeners (default: off).  Needs TLS
configured (croaks otherwise) and L<Alien::nghttp2> at build time.

=item sni

SNI virtual hosting: an arrayref of C<< { sni => $hostname, cert_file => $path,
key_file => $path } >> hashes, each adding a certificate for that hostname.
Requires C<tls> (the default certificate); croaks without it.

=item reuseport

Use C<SO_REUSEPORT> with C<pre_fork> (default: off): each worker binds its own
socket to the same address and the kernel spreads connections across them,
removing accept() contention.  Needs Linux 3.9+ or equivalent.

Each worker binds for itself, which C<user>/C<group> on a port below 1024
makes impossible; Feersum probes the bind while dropping privileges and falls
back to the shared inherited socket, with a warning.

A reuseport socket owns its accept queue, so a retiring or restarting worker
would reset whatever the kernel had queued on it.  Reuseport workers therefore
run with C<set_drain_accept_queue> (see L<Feersum>) and serve that queue as
part of the graceful drain.  What remains is a small window of refused
connects between a worker closing its listener and its replacement binding;
Linux 5.14+ removes it with C<net.ipv4.tcp_migrate_req=1>.

Not required for IPv6; see C<listen>.

=item max_requests_per_worker

Requests a worker serves before retiring and being replaced (default: 0,
unlimited).  Effective with C<pre_fork> or C<hot_restart>.  The limit is exact
(enforced in XS; see L<Feersum/"max_requests_per_worker()">), retirement is
not counted as a crash for respawn backoff, and C<graceful_timeout> bounds
the retiring worker's drain since the replacement is forked only once it
exits.

=item access_log

Code reference called after each response completes (native handler only).
Receives C<($method, $uri, $elapsed_seconds)>.  Requests the server rejects
before dispatch (malformed, over a limit, timed out) produce no line; see
C<access_log> in L<Feersum>.  For PSGI apps, use
L<Plack::Middleware::AccessLog> instead.

    access_log => sub {
        my ($method, $uri, $elapsed) = @_;
        warn sprintf "%s %s %.3fms\n", $method, $uri, $elapsed * 1000;
    },

=item graceful_timeout

Seconds to let in-flight requests finish on shutdown or worker retirement
before force-exiting (default: 5; 0 force-exits at once).  The
C<FEERSUM_GRACEFUL_TIMEOUT> environment variable is used when the option is
unset.  A prefork parent allows 2 extra seconds so its workers exit first.
Force-exit truncates whatever is still in flight, so raise it if you serve
large or long-streaming responses.

=item startup_timeout

Seconds to wait for a C<hot_restart> generation to report ready before rolling
back (default: 10).  Also caps how long a C<daemonize> parent waits for the
daemon's readiness report; there a timeout counts as success.

=item after_fork

Code reference called in each worker child immediately after fork, before
entering the event loop.  Use this to reconnect database handles, reseed
PRNGs, or close inherited file descriptors:

    after_fork => sub { $dbh = DBI->connect(...) },

=item pid_file

Write the server PID to this file.  Removed on clean shutdown.

=item daemonize

Fork into background, redirect STDIN/STDOUT/STDERR to /dev/null,
and call C<setsid()>.  The PID file (if specified) is written with the
daemon's PID.

=item user

=item group

Drop privileges after the listen sockets are bound and before the app loads,
so a root start can bind privileged ports.  Supplementary groups are always
cleared; with C<group> omitted the user's primary group is used.  The drop is
verified and croaks if it did not take effect.

The TLS certificate and key must be readable by C<user>: a worker respawn
re-reads them after the drop, so a root-only key works at startup and then
empties the pool at the first respawn (silently under C<daemonize>).

=item max_h2_concurrent_streams

Maximum concurrent HTTP/2 streams per connection (default: 100).
Requires H2 support compiled in.

=item max_h2_conn_body

Aggregate cap on request-body bytes buffered across a connection's HTTP/2
streams (default: 0, off).  Bounds the memory a peer can tie up with many
concurrent uploads; see L<Feersum/"max_h2_conn_body()">.  Requires H2 support.

=item quiet

Don't be so noisy. (default: on)

=item app

An already-compiled native Feersum app code reference, as an alternative to
passing it to C<run()>.  Mutually exclusive with a per-worker load: when C<app>
is set, C<app_file> is not re-read in the workers.

=item app_file

Load this filename as a native feersum app.  Required for C<hot_restart>, which
re-reads the file in each new generation.  With C<preload_app> off and no
C<app>, each worker loads it independently after the fork.

=back

=item C<< $runner->run($feersum_app) >>

Run Feersum with the specified app code reference.  Note that this is not a
PSGI app, but a native Feersum app.

=item C<< $runner->assign_request_handler($subref) >>

For sub-classes to override, assigns an app handler. (e.g.
L<Plack::Handler::Feersum>).  By default, this assigns a Feersum-native (and
not PSGI) handler.

=item C<< $runner->quit() >>

Initiate a graceful shutdown.  A signal handler for SIGQUIT will call this
method.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14 or,
at your option, any later version of Perl 5 you may have available.

=cut
