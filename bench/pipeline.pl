#!/usr/bin/env perl
# Pipeline benchmark: measures effect of HTTP/1.1 pipelining depth
# Sends N requests per write, reads all responses, measures throughput.
use strict;
use warnings;
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time);
use Getopt::Long;
use File::Temp qw(tempdir);
use Storable qw(nstore retrieve);

my $port       = 5010;
my $duration   = 5;
my $clients    = 50;
my $depths_str = '1,2,4,8,16,32';
my $mode       = 'native';  # native or psgi
my $no_server  = 0;

GetOptions(
    'port=i'     => \$port,
    'duration=i' => \$duration,
    'clients=i'  => \$clients,
    'depths=s'   => \$depths_str,
    'mode=s'     => \$mode,
    'no-server'  => \$no_server,
) or die "Usage: $0 [--port PORT] [--duration SEC] [--clients N] [--depths 1,2,4,8] [--mode native|psgi] [--no-server]\n";

my @depths = split /,/, $depths_str;
my $tmpdir = tempdir(CLEANUP => 1);

# -- Start server --------------------------------------------------

my $server_pid;
unless ($no_server) {
    $server_pid = fork // die "fork: $!";
    if ($server_pid == 0) {
        if ($mode eq 'psgi') {
            exec($^X, '-Iblib/lib', '-Iblib/arch', 'bench/psgi_server.pl',
                 '--port', $port, '--keepalive');
        } else {
            exec($^X, '-Iblib/lib', '-Iblib/arch', 'bench/native.pl', $port);
        }
        die "exec: $!";
    }
    # NB `kill 0` succeeds on an unreaped zombie, so it cannot tell a dead
    # server from a live one: a server that failed to bind was published as a
    # benchmark result of 0 req/s with exit status 0.  Reap-check instead, and
    # confirm something is actually listening.
    my $up = 0;
    for (1 .. 40) {
        select undef, undef, undef, 0.25;   # give it time to fail first
        die "Server exited during startup (see its error above)\n"
            if waitpid($server_pid, POSIX::WNOHANG()) > 0;
        if (IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1)) {
            $up = 1;
            last;
        }
    }
    die "Server failed to start (nothing listening on port $port)\n" unless $up;
}

my $request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";

# Pre-compute pipelined request batches
my %batch;
for my $d (@depths) {
    $batch{$d} = $request x $d;
}

printf "%-40s %s\n", "Pipeline Benchmark", "$mode mode";
printf "%-40s %ds, %d clients\n", "", $duration, $clients;
printf "%s\n", "=" x 65;
printf "%-8s %12s %12s %12s %12s\n",
    "Depth", "req/s", "MB/s", "lat(mean)", "lat(p99)";
printf "%s\n", "-" x 65;

for my $depth (@depths) {
    run_benchmark($depth);
}

printf "%s\n", "=" x 65;

if ($server_pid) {
    kill 'QUIT', $server_pid;
    waitpid $server_pid, 0;
}

sub run_benchmark {
    my ($depth) = @_;
    my $batch_data = $batch{$depth};

    my @pids;
    for my $c (0 .. $clients - 1) {
        my $pid = fork // die "fork: $!";
        if ($pid == 0) {
            my ($reqs, $bytes, $lats) =
                client_loop($depth, $batch_data, $duration);
            nstore([$reqs, $bytes, $lats], "$tmpdir/result_${depth}_${c}");
            exit 0;
        }
        push @pids, $pid;
    }

    waitpid($_, 0) for @pids;

    # Aggregate
    my ($total_reqs, $total_bytes) = (0, 0);
    my @all_latencies;
    for my $c (0 .. $clients - 1) {
        my $f = "$tmpdir/result_${depth}_${c}";
        next unless -f $f;
        my $r = retrieve($f);
        $total_reqs  += $r->[0];
        $total_bytes += $r->[1];
        push @all_latencies, @{$r->[2]} if $r->[2];
        unlink $f;
    }

    my $rps  = $total_reqs / $duration;
    my $mbps = $total_bytes / $duration / 1048576;

    @all_latencies = sort { $a <=> $b } @all_latencies;
    my ($lat_mean, $lat_p99) = (0, 0);
    if (@all_latencies) {
        my $sum = 0;
        $sum += $_ for @all_latencies;
        $lat_mean = $sum / @all_latencies;
        $lat_p99  = $all_latencies[int($#all_latencies * 0.99)];
    }

    printf "%-8d %12.0f %12.2f %12s %12s\n",
        $depth, $rps, $mbps, fmt_us($lat_mean), fmt_us($lat_p99);
}

sub client_loop {
    my ($depth, $batch_data, $duration) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => "127.0.0.1:$port",
        Proto    => 'tcp',
    ) or return (0, 0, []);

    my $end = time() + $duration;
    my $total_reqs  = 0;
    my $total_bytes = 0;
    my @latencies;
    my $sample = 0;
    my $batch_len = length $batch_data;

    my $buf = '';

    while (time() < $end) {
        my $t0 = time();

        # Send pipelined batch
        my $written = 0;
        while ($written < $batch_len) {
            my $n = syswrite($sock, $batch_data, $batch_len - $written, $written);
            goto DONE unless defined $n;
            $written += $n;
        }

        # Read all responses
        my $responses_read = 0;
        while ($responses_read < $depth) {
            # Find end of headers
            my $hdr_end;
            while (($hdr_end = index($buf, "\r\n\r\n")) < 0) {
                my $n = sysread($sock, $buf, 65536, length $buf);
                goto DONE unless $n;
                $total_bytes += $n;
            }
            $hdr_end += 4;  # include the \r\n\r\n

            # Extract Content-Length from headers
            my $hdr = substr($buf, 0, $hdr_end);
            my $cl = 0;
            if ($hdr =~ /Content-Length:\s*(\d+)/i) {
                $cl = $1;
            }

            # Consume headers + body
            my $total_msg = $hdr_end + $cl;
            while (length($buf) < $total_msg) {
                my $n = sysread($sock, $buf, 65536, length $buf);
                goto DONE unless $n;
                $total_bytes += $n;
            }
            substr($buf, 0, $total_msg, '');
            $responses_read++;
        }

        $total_reqs += $depth;

        # Sample latency every 10th batch
        if (++$sample % 10 == 0) {
            push @latencies, (time() - $t0) / $depth;
        }
    }

    DONE:
    close $sock;
    return ($total_reqs, $total_bytes, \@latencies);
}

sub fmt_us {
    my $s = shift;
    if    ($s >= 0.001)   { sprintf "%.2fms", $s * 1000 }
    elsif ($s >= 0.000001){ sprintf "%.0fus",  $s * 1_000_000 }
    else                  { sprintf "%.0fns",  $s * 1_000_000_000 }
}
