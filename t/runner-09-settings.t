#!perl
# Every @SIMPLE_SETTINGS row in Feersum::Runner must reach its XS setter, on
# the initial instance and again in a hot_restart generation; a dropped row
# is accepted, validated and silently ignored.
use warnings;
use strict;
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 3 : 1);
use Test::More tests => 10;  # 8 explicit + 2 simple_client implicit
use lib 't'; use Utils;
use Feersum ();
use File::Temp qw(tempdir);
use POSIX ();

my $parent_pid = $$;
END { $? = 0 if $$ != $parent_pid }
my @_kill_on_exit;
END { kill 'QUIT', @_kill_on_exit if $$ == $parent_pid && @_kill_on_exit }

# Deliberately non-default values so a setting that never reaches the server is
# visible as a mismatch rather than an accidental match.
my %WANT = (
    read_timeout              => 11,
    header_timeout            => 12,
    write_timeout             => 13,
    max_connection_reqs       => 14,
    read_priority             => 1,
    write_priority            => -1,
    accept_priority           => 2,
    max_accept_per_loop       => 15,
    max_connections           => 16,
    max_read_buf              => 17000,
    max_body_len              => 18000,
    max_uri_len               => 1900,
    wbuf_low_water            => 20,
    max_h2_concurrent_streams => 21,
);

# Without HTTP/2 compiled in the setter warns and ignores the value and the
# getter returns 0, so this row can only be checked on an H2-enabled build.
delete $WANT{max_h2_concurrent_streams} unless Feersum->new->has_h2;

my $dir = tempdir(CLEANUP => 1);
my $app = "$dir/settings.feersum";
# The app reports what the server ACTUALLY has, read back through the getters.
open my $fh, '>', $app or die;
print $fh <<'APP';
sub {
    my $r = shift;
    my $f = Feersum->endjinn;
    my @out;
    for my $m (sort qw(read_timeout header_timeout write_timeout
                       max_connection_reqs read_priority write_priority
                       accept_priority max_accept_per_loop max_connections
                       max_read_buf max_body_len max_uri_len wbuf_low_water
                       max_h2_concurrent_streams)) {
        my $v = eval { $f->$m() };
        push @out, "$m=" . (defined $v ? $v : 'undef');
    }
    my $body = join(",", @out);
    $r->send_response(200, ['Content-Type' => 'text/plain'], \$body);
}
APP
close $fh;

sub fetch_settings {
    my ($port) = @_;
    my $body;
    my $cv = AE::cv;
    my $cli; $cli = simple_client GET => '/settings', port => $port,
        timeout => 5 * TIMEOUT_MULT, sub {
            my ($b, $h) = @_;
            $body = $b if $h->{Status} && $h->{Status} == 200;
            $cv->send; undef $cli;
        };
    $cv->recv;
    return {} unless defined $body;
    return { map { /^([^=]+)=(.*)$/ ? ($1 => $2) : () } split /,/, $body };
}

my (undef, $port) = get_listen_socket();
my $pid = fork // die "fork: $!";
push @_kill_on_exit, $pid if $pid;
if (!$pid) {
    require Feersum::Runner;
    eval {
        Feersum::Runner->new(
            listen => ["localhost:$port"], app_file => $app,
            hot_restart => 1, quiet => 1, %WANT,
        )->run();
    };
    POSIX::_exit(0);
}

select undef, undef, undef, 2 * TIMEOUT_MULT;

my $got = fetch_settings($port);
ok scalar(keys %$got), 'server reported its settings';

my @wrong = grep { ($got->{$_} // 'missing') ne $WANT{$_} } sort keys %WANT;
is scalar(@wrong), 0,
    'every Runner tunable reached the server'
    or diag "not applied: " . join(', ',
        map { "$_ wanted=$WANT{$_} got=" . ($got->{$_} // 'missing') } @wrong);

# Spot-check a couple explicitly so a future refactor of the loop above cannot
# quietly turn this file into a tautology.
is $got->{max_body_len}, 18000, 'max_body_len applied';
is $got->{read_timeout}, 11,    'read_timeout applied';

#######################################################################
# A hot_restart generation must RE-APPLY the same settings.  _apply_settings
# runs for every generation, but no test passed a single tunable, so a
# regression there would silently revert a reloaded server to defaults.
#######################################################################
kill 'HUP', $pid;
select undef, undef, undef, 3 * TIMEOUT_MULT;

my $got2 = fetch_settings($port);
ok scalar(keys %$got2), 'server still serving after HUP reload';

my @wrong2 = grep { ($got2->{$_} // 'missing') ne $WANT{$_} } sort keys %WANT;
is scalar(@wrong2), 0,
    'settings survive a hot_restart reload'
    or diag "reverted after HUP: " . join(', ',
        map { "$_ wanted=$WANT{$_} got=" . ($got2->{$_} // 'missing') } @wrong2);

is $got2->{max_body_len}, 18000, 'max_body_len still applied after reload';

kill 'QUIT', $pid;
my $reaped = 0;
for (1 .. 40) {
    select undef, undef, undef, 0.25 * TIMEOUT_MULT;
    if (waitpid($pid, POSIX::WNOHANG()) > 0) { $reaped = 1; last }
}
unless ($reaped) { kill 'KILL', $pid; waitpid $pid, 0 }
@_kill_on_exit = ();
ok $reaped, 'hot_restart master shut down on SIGQUIT';
