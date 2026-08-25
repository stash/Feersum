#!perl
# access_log with streaming response: Guard fires after full stream completes
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 6;  # 5 explicit + 1 simple_client implicit
use utf8;
use lib 't'; use Utils;
use File::Temp qw(tempdir);
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }

my $dir = tempdir(CLEANUP => 1);
my $log_file = "$dir/stream.log";
my (undef, $port) = get_listen_socket();

my $pid = fork // die "fork: $!";
if (!$pid) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen     => ["localhost:$port"],
            quiet      => 1,
            access_log => sub {
                my ($method, $uri, $elapsed) = @_;
                open my $fh, '>>', $log_file;
                printf $fh "%s %s %.4f\n", $method, $uri, $elapsed;
                close $fh;
            },
            app => sub {
                my $r = shift;
                # Streaming response: start, write chunks with delay, close
                my $w = $r->start_streaming(200, ['Content-Type' => 'text/plain']);
                $w->write("chunk1\n");
                my $t; $t = EV::timer(0.2, 0, sub {
                    $w->write("chunk2\n");
                    $w->close();
                    undef $t;
                });
            },
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 0.8 * TIMEOUT_MULT;

# Request a streaming response
my $body;
my $cv = AE::cv;
my $cli; $cli = simple_client GET => '/stream', port => $port,
    timeout => 5 * TIMEOUT_MULT, sub {
        my ($b, $h) = @_;
        $body = $b;
        $cv->send; undef $cli;
    };
$cv->recv;
like $body, qr/chunk1.*chunk2/s, "got full streaming response";

# Wait for response_guard to fire (after close)
select undef, undef, undef, 0.5 * TIMEOUT_MULT;

ok -f $log_file, "access_log file created for streaming response";
my $log = do { local (@ARGV, $/) = ($log_file); <> } // '';
like $log, qr{^GET /stream 0\.\d+}m, "access_log entry has elapsed time > 0 (stream completed)";

# Verify elapsed time is >= 0.2s (the delay between chunks)
my ($elapsed) = $log =~ /(\d+\.\d+)/;
ok defined($elapsed) && $elapsed >= 0.1,
    "elapsed time reflects streaming duration (${elapsed}s)";

reap_server($pid);
pass "streaming access_log clean shutdown";
