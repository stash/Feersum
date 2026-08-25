package Utils;
use strict;
use Test::More ();
use Socket qw/SOMAXCONN/;
use IO::Socket::INET;
use blib;
use Carp qw(carp croak);
use File::Spec ();
use Encode ();
use POSIX ();
use AnyEvent ();
use AnyEvent::Handle ();
use Guard ();
use Scalar::Util qw/blessed weaken/;
use utf8;

$SIG{PIPE} = 'IGNORE';

my $CRLF = "\015\012";

sub import {
    my ($pkg) = caller;
    no strict 'refs';
    *{$pkg.'::carp'} = \&Carp::carp;
    *{$pkg.'::croak'} = \&Carp::croak;
    *{$pkg.'::guard'} = \&Guard::guard;
    *{$pkg.'::scope_guard'} = \&Guard::scope_guard;
    *{$pkg.'::weaken'} = \&Scalar::Util::weaken;
    *{$pkg.'::blessed'} = \&Scalar::Util::blessed;
    *{$pkg.'::get_listen_socket'} = \&get_listen_socket;
    *{$pkg.'::simple_client'} = \&simple_client;
    *{$pkg.'::build_proxy_v1'} = \&build_proxy_v1;
    *{$pkg.'::build_proxy_v2'} = \&build_proxy_v2;
    *{$pkg.'::run_client'} = \&run_client;
    *{$pkg.'::tls_client_ok'} = \&tls_client_ok;
    *{$pkg.'::reap_server'} = \&reap_server;
    *{$pkg.'::run_capped'} = \&run_capped;

    return 1;
}

# Run a command with a wall-clock cap and return whatever it printed, including
# the partial output of a run we had to kill.
#
# This replaces `timeout N cmd ...` in backticks.  timeout(1) is GNU coreutils:
# it does not exist on macOS or the BSDs, where the shell-out failed outright
# and the test then matched its assertion against "sh: timeout: command not
# found" instead of against the server's response.
#
# The ALRM handler kills the child but does NOT die: the pipe then reaches EOF,
# the read loop ends normally, and we keep what the command managed to emit -
# which is what timeout(1) gives you and what the callers rely on.
sub run_capped {
    my ($secs, $cmd, %opt) = @_;
    my $pid = open(my $fh, '-|');
    return '' unless defined $pid;
    if (!$pid) {
        if ($opt{merge_stderr}) { open STDERR, '>&', \*STDOUT }
        else { open STDERR, '>', File::Spec->devnull }
        exec @$cmd;
        POSIX::_exit(127);
    }
    my $out = '';
    {
        local $SIG{ALRM} = sub { kill 'KILL', $pid };
        alarm $secs;
        while (1) {
            my $n = sysread($fh, my $buf, 65536);
            last if !defined $n || $n == 0;
            $out .= $buf;
        }
        alarm 0;
    }
    close $fh;
    waitpid $pid, 0;
    return $out;
}

# Stop a forked test server and reap it, without ever blocking indefinitely.
#
# `kill 'QUIT', $pid; waitpid $pid, 0` is NOT safe here: on some platforms
# (alpine/musl CI containers) SIGQUIT does not terminate the server child at
# all, so waitpid blocks until whatever life-limit timer the test armed fires.
# That turned the suite into ~23 minutes of pure waiting on alpine and, before
# those timers were assigned to a variable and therefore actually armed, into
# a hang with no upper bound.  Signal, wait briefly, then escalate.
sub reap_server {
    my ($pid, $secs) = @_;
    return unless $pid;
    $secs ||= 5;
    kill 'QUIT', $pid;
    my $deadline = time + $secs;
    while (time <= $deadline) {
        return $pid if waitpid($pid, POSIX::WNOHANG()) > 0;
        select undef, undef, undef, 0.05;
    }
    kill 'KILL', $pid;
    return waitpid($pid, 0);
}

our $last_port;
sub get_listen_socket {
    # Kernel-assigned ephemeral port (LocalPort=>0). Avoids predictable
    # 10000+ walking that, on shared CI smokers running parallel perl builds,
    # let stale connections from a previous test leak via SO_REUSEADDR into
    # the next test's listener (firing handler tests with no expected headers
    # and breaking the planned test count).
    my $socket = IO::Socket::INET->new(
        LocalAddr => 'localhost',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => SOMAXCONN,
        Blocking  => 0,
    ) or return;
    my $port = $socket->sockport;
    $last_port = $port;
    return wantarray ? ($socket, $port) : $socket;
}

sub _cb_ewrapper {
    my ($code, $name) = @_;
    return(sub {}) unless $code;
    return sub {
        eval { $code->(@_) };
        if ($@) {
            Test::More::fail "$name callback failed";
            Test::More::diag $@
        }
    };
}

sub simple_client ($$;@) {
    my $done_cb = pop;
    my $method = shift;
    my $uri = shift;
    my %opts = @_;

    my $name = delete $opts{name} || 'simple_client';
    my $port = delete $opts{port} || $last_port;

    $done_cb = _cb_ewrapper($done_cb, "$name done");
    my $conn_cb = _cb_ewrapper(delete $opts{on_connect}, "$name connect");
    my $buf = '';
    my %hdrs;
    my $err_cb = sub {
        my ($h,$fatal,$msg) = @_;
        $hdrs{Status} = 599;
        $hdrs{Reason} = $msg;
        $h->destroy;
        $done_cb->(undef,\%hdrs);
    };

    require AnyEvent::Handle;
    my $h; $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1',$port],
        on_connect => sub {
            my $h = shift;
            Test::More::pass("$name connected");
            $conn_cb->($h);
            return;
        },
        on_error => $err_cb,
        timeout => $opts{timeout} || 30,
    );
    my $strong_h = $h;
    weaken($h);

    my $done = sub { $done_cb->($buf,\%hdrs); $h->destroy if $h; };

    $h->on_read(sub {
        Test::More::fail "$name got extra bytes!";
    });
    $h->push_read(line => "$CRLF$CRLF", sub {
        {
            my @hdrs = split($CRLF, $_[1]);
            my $status_line = shift @hdrs;
            %hdrs = map {
                my ($k,$v) = split(/:\s+/,$_,2);
                (lc($k),$v);
            } @hdrs;
            if ($status_line =~ m{HTTP/(1\.\d) (\d{3}) +(.+)\s*}) {
                $hdrs{HTTPVersion} = $1;
                $hdrs{Status} = $2;
                $hdrs{Reason} = $3;
            }
        }

        $hdrs{'content-length'} = 0 if ($hdrs{Status} == 204);

        if ($hdrs{Status} == 304) {
            # should have no body
            $h->on_read(sub {
                $buf .= substr($_[0]->{rbuf},0,length($_[0]->{rbuf}),'');
            });
            $h->on_eof($done);
        }
        elsif (exists $hdrs{'content-length'}) {
            return $done->() unless ($hdrs{'content-length'});
            $h->push_read(chunk => $hdrs{'content-length'}, sub {
                $buf = $_[1];
                return $done->();
            });
        }
        elsif (($hdrs{'transfer-encoding'}||'') eq 'chunked') {
            my $len = 0;
            my ($chunk_reader, $chunk_handler);
            $chunk_handler = sub {
                if ($len == 0) {
                    undef $chunk_reader;
                    undef $chunk_handler;
                    return $done->();
                }
                # remove CRLF at end of chunk:
                $buf .= substr($_[1],0,-2);
                $h->push_read(line => $CRLF, $chunk_reader);
            };
            $chunk_reader = sub {
                my $hex = $_[1];
                if ($hex !~ /^[0-9a-fA-F]+$/) {
                    $err_cb->($h,0,"invalid chunk length '$hex'");
                    undef $chunk_reader;
                    undef $chunk_handler;
                    return;
                }
                $len = hex $hex;
                {
                    # add two for after-chunk CRLF
                    $h->push_read(chunk => $len+2, $chunk_handler);
                }
            };
            $h->push_read(line => $CRLF, $chunk_reader);
        }
        elsif ($hdrs{HTTPVersion} eq '1.0' or
               ($hdrs{connection}||'') eq 'close')
        {
            $h->on_read(sub {
                $buf .= substr($_[0]->{rbuf},0,length($_[0]->{rbuf}),'');
            });
            $h->on_eof($done);
        }
        else {
            $err_cb->($h,0,
                "got a response that I don't know how to handle the body for");
            return;
        }
    });

    my $host = 'localhost';
    my $headers = delete $opts{headers};
    my $proto = delete $opts{proto} || '1.1';
    my $body = delete $opts{body} || '';

    $headers->{'User-Agent'} ||= 'FeersumSimpleClient/1.0';
    $headers->{'Host'} ||= $host.':'.$port;
    if (length($body)) {
        $headers->{'Content-Length'} ||= length($body);
        $headers->{'Content-Type'} ||= 'text/plain';
    }

    # HTTP/1.1 default is 'keep-alive'
    $headers->{'Connection'} ||= 'close' if $proto eq '1.1' && !$opts{keepalive};

    my $head = join($CRLF, map {$_.': '.$headers->{$_}} sort keys %$headers);

    my $http_req = "$method $uri HTTP/$proto$CRLF";
    $strong_h->push_write($http_req);

    $strong_h->push_write($head.$CRLF.$CRLF.$body)
        unless $opts{skip_head};

    return $strong_h;
}

# Build PROXY protocol v1 header (text format)
# Usage: build_proxy_v1('TCP4', '192.0.2.1', '192.0.2.2', 12345, 80)
#        build_proxy_v1('UNKNOWN')  # for health checks
sub build_proxy_v1 {
    my ($proto, $src_ip, $dst_ip, $src_port, $dst_port) = @_;

    if ($proto eq 'UNKNOWN') {
        return "PROXY UNKNOWN\r\n";
    }

    return "PROXY $proto $src_ip $dst_ip $src_port $dst_port\r\n";
}

# Build PROXY protocol v2 header (binary format)
# $cmd: 'LOCAL' or 'PROXY'
# $family: 'UNSPEC', 'INET' (IPv4), 'INET6' (IPv6), or 'UNIX' (AF_UNIX)
# For PROXY command with INET/INET6, provide addresses; for UNIX, src_ip and
# dst_ip carry the socket paths (each null-padded to 108 bytes)
sub build_proxy_v2 {
    my ($cmd, $family, $src_ip, $dst_ip, $src_port, $dst_port, $tlvs) = @_;

    # v2 signature
    my $sig = "\x0D\x0A\x0D\x0A\x00\x0D\x0A\x51\x55\x49\x54\x0A";

    # version (2) and command
    my $ver_cmd;
    if ($cmd eq 'LOCAL') {
        $ver_cmd = 0x20 | 0x00;  # version 2, LOCAL command
    } elsif ($cmd eq 'PROXY') {
        $ver_cmd = 0x20 | 0x01;  # version 2, PROXY command
    } else {
        croak "Unknown command: $cmd";
    }

    # family and protocol
    my ($fam_proto, $addr_data);
    if ($family eq 'UNSPEC') {
        $fam_proto = 0x00;
        $addr_data = '';
    } elsif ($family eq 'INET') {
        $fam_proto = 0x11;  # AF_INET + STREAM
        # Pack IPv4 addresses
        my $src_packed = Socket::inet_aton($src_ip) or croak "Invalid src IP: $src_ip";
        my $dst_packed = Socket::inet_aton($dst_ip) or croak "Invalid dst IP: $dst_ip";
        $addr_data = $src_packed . $dst_packed . pack('nn', $src_port, $dst_port);
    } elsif ($family eq 'INET6') {
        $fam_proto = 0x21;  # AF_INET6 + STREAM
        # Pack IPv6 addresses
        my $src_packed = Socket::inet_pton(Socket::AF_INET6(), $src_ip)
            or croak "Invalid src IPv6: $src_ip";
        my $dst_packed = Socket::inet_pton(Socket::AF_INET6(), $dst_ip)
            or croak "Invalid dst IPv6: $dst_ip";
        $addr_data = $src_packed . $dst_packed . pack('nn', $src_port, $dst_port);
    } elsif ($family eq 'UNIX') {
        $fam_proto = 0x31;  # AF_UNIX + STREAM
        # 2 x 108-byte null-padded paths (src_ip/dst_ip carry the paths)
        $addr_data = pack('Z108', $src_ip // '') . pack('Z108', $dst_ip // '');
    } else {
        croak "Unknown family: $family";
    }

    # Append TLVs if provided (arrayref of [type, value] pairs)
    my $tlv_data = '';
    if ($tlvs && ref($tlvs) eq 'ARRAY') {
        for my $tlv (@$tlvs) {
            my ($type, $value) = @$tlv;
            $tlv_data .= chr($type) . pack('n', length($value)) . $value;
        }
    }

    my $addr_len = length($addr_data) + length($tlv_data);

    return $sig . chr($ver_cmd) . chr($fam_proto) . pack('n', $addr_len) . $addr_data . $tlv_data;
}

sub tls_client_ok {
    eval { require Net::SSLeay; 1 } or return 0;
    return Net::SSLeay::SSLeay() >= 0x10101000; # OpenSSL >= 1.1.1 for TLS 1.3 client
}

sub run_client {
    my ($label, $code) = @_;
    my $tmult = $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 2 : 1);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        select(undef, undef, undef, 0.3 * $tmult);
        my $rc = eval { $code->() };
        if ($@) { warn "$label client error: $@\n"; exit(99); }
        exit($rc || 0);
    }
    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer(15 * $tmult, 0, sub { kill 'QUIT', $pid; $cv->send('timeout') });
    my $w = AE::child($pid, sub { $child_status = $_[1] >> 8; $cv->send('done') });
    my $reason = $cv->recv;
    Test::More::isnt($reason, 'timeout', "$label: did not timeout");
    Test::More::is($child_status, 0, "$label: client passed");
}

1;
