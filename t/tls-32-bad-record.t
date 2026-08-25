#!perl
# A TLS record that fails to decrypt terminates the connection (RFC 8446 5.2)
# even when it lands in the multi-record drain loop, while a peer close_notify
# in that same loop must not discard an already-decrypted request.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);
use Test::More;
use lib 't'; use Utils;

BEGIN {
    require Feersum;
    my $f = Feersum->endjinn;
    plan skip_all => "TLS not compiled in" unless $f->has_tls();
    eval { require IO::Socket::SSL; require Net::SSLeay; 1 }
        or plan skip_all => "IO::Socket::SSL/Net::SSLeay not available";
    plan skip_all => "OpenSSL too old for TLS 1.3 client" unless tls_client_ok();
    plan skip_all => "test certs not found"
        unless -f 'eg/ssl-proxy/server.crt' && -f 'eg/ssl-proxy/server.key';
    plan tests => 3;
}

use IO::Socket::INET;
use IO::Select;
use POSIX ();
use Socket qw(SOMAXCONN);
use Time::HiRes qw(time);
use File::Temp qw(tempdir);

my $cert = 'eg/ssl-proxy/server.crt';
my $key  = 'eg/ssl-proxy/server.key';
my $dir  = tempdir(CLEANUP => 1);
my $READ_TIMEOUT = 3 * TIMEOUT_MULT;

# A TLS server whose handler notes each path it served into $log.
sub start_server {
    my ($log) = @_;
    my $lsn = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', ReuseAddr => 1, Proto => 'tcp',
        Listen => SOMAXCONN, Blocking => 0,
    ) or die "listen: $!";
    my $port = $lsn->sockport;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        # A bare Feersum child can inherit SIG_IGN for QUIT (make test on
        # alpine does this), making the kill below a no-op.
        $SIG{QUIT} = q{DEFAULT};
        my $evh = Feersum->endjinn;
        $evh->use_socket($lsn);
        $evh->set_tls(cert_file => $cert, key_file => $key);
        # Keepalive is what makes the stall observable: without it the
        # connection closes after the response no matter what the drain did.
        $evh->set_keepalive(1);
        $evh->read_timeout($READ_TIMEOUT);
        $evh->request_handler(sub {
            my $r = shift;
            if (open my $fh, '>>', $log) {
                print $fh $r->env->{PATH_INFO}, "\n";
                close $fh;
            }
            $r->send_response("200 OK", ['Content-Length' => 2], "OK");
        });
        EV::run();
        POSIX::_exit(0);
    }
    close $lsn;
    return ($pid, $port);
}

# Relay to $to, re-framing the client's TLS records per $mode.  A TLS 1.3
# client's first application-typed record is its encrypted Finished, so the
# request is the second and any close_notify the third.
sub start_proxy {
    my ($to, $mode, $flagfile) = @_;
    my $lsn = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', ReuseAddr => 1, Proto => 'tcp', Listen => 5,
    ) or die "proxy listen: $!";
    my $port = $lsn->sockport;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        # A bare Feersum child can inherit SIG_IGN for QUIT (make test on
        # alpine does this), making the kill below a no-op.
        $SIG{QUIT} = q{DEFAULT};
        my $cli = $lsn->accept          or POSIX::_exit(1);
        my $srv = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $to)
                                        or POSIX::_exit(1);
        my ($buf, $seen, $held) = ('', 0, '');
        my $sel = IO::Select->new($cli, $srv);
        OUTER: while (my @ready = $sel->can_read(10 * TIMEOUT_MULT)) {
            for my $fh (@ready) {
                my $n = sysread($fh, my $chunk, 65536);
                last OUTER if !defined $n || $n == 0;
                if ($fh == $srv) { syswrite($cli, $chunk); next }
                $buf .= $chunk;
                my $out = '';
                while (length($buf) >= 5) {
                    my ($type, undef, $len) = unpack("C n n", $buf);
                    last if length($buf) < 5 + $len;
                    my $rec = substr($buf, 0, 5 + $len, '');
                    $seen++ if $type == 23;
                    if ($type != 23) { $out .= $rec; next }
                    if ($mode eq 'dup' && $seen == 2) {
                        if (open my $fh2, '>', $flagfile) { close $fh2 }
                        $out .= $rec . $rec;    # one write -> one server read
                    }
                    elsif ($mode eq 'hold' && $seen == 2) { $held = $rec }
                    elsif ($mode eq 'hold' && $seen == 3) {
                        if (open my $fh2, '>', $flagfile) { close $fh2 }
                        $out .= $held . $rec;
                        $held = '';
                    }
                    else { $out .= $rec }
                }
                syswrite($srv, $out) if length $out;
            }
        }
        POSIX::_exit(0);
    }
    close $lsn;
    return ($pid, $port);
}

sub connect_tls {
    my ($port) = @_;
    return IO::Socket::SSL->new(
        PeerAddr        => '127.0.0.1',
        PeerPort        => $port,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        Timeout         => 5 * TIMEOUT_MULT,
    );
}

# --- A: a record that fails AEAD mid-batch must not strand the connection ---
{
    my $flag = "$dir/dup";
    my ($spid, $sport) = start_server("$dir/a.log");
    my ($ppid, $pport) = start_proxy($sport, 'dup', $flag);
    select undef, undef, undef, 0.5 * TIMEOUT_MULT;

    my $elapsed = 3600;
    if (my $c = connect_tls($pport)) {
        my $t0 = time;
        print $c "GET /dup HTTP/1.1\r\nHost: x\r\n\r\n";
        eval {
            local $SIG{ALRM} = sub { die "hang\n" };
            alarm int($READ_TIMEOUT * 3);
            1 while sysread($c, my $chunk, 65536);
            alarm 0;
            1;
        } or alarm 0;
        $elapsed = time - $t0;
        close $c;
    }
    else { diag "TLS connect failed: " . IO::Socket::SSL::errstr() }

    ok -e $flag, "proxy duplicated an application record";
    cmp_ok $elapsed, '<', $READ_TIMEOUT / 2,
        sprintf("undecryptable record closed the connection (%.2fs, read_timeout %ds)",
                $elapsed, $READ_TIMEOUT);

    kill 'QUIT', $spid, $ppid;
    waitpid($_, 0) for $spid, $ppid;
}

# --- B: a request coalesced with the client's close_notify is still served ---
{
    my $log = "$dir/b.log";
    my ($spid, $sport) = start_server($log);
    my ($ppid, $pport) = start_proxy($sport, 'hold', "$dir/held");
    select undef, undef, undef, 0.5 * TIMEOUT_MULT;

    if (my $c = connect_tls($pport)) {
        print $c "GET /coalesced HTTP/1.1\r\nHost: x\r\n\r\n";
        $c->stop_SSL(SSL_fast_shutdown => 1);   # close_notify; proxy pairs it up
        select undef, undef, undef, 1.5 * TIMEOUT_MULT;
        close $c;
    }
    else { diag "TLS connect failed: " . IO::Socket::SSL::errstr() }

    my $served = '';
    if (open my $fh, '<', $log) { local $/; $served = <$fh> || '' }
    $served =~ s/\s+\z//;
    is $served, '/coalesced',
        "request coalesced with close_notify is still served";

    kill 'QUIT', $spid, $ppid;
    waitpid($_, 0) for $spid, $ppid;
}
