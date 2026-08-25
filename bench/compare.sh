#!/bin/bash
# Compare Feersum PSGI performance against other Perl HTTP servers.
# Requires: wrk (or h2load), and optionally Gazelle, Starlet, Twiggy, Mojolicious
#
# NB on fairness: both Feersum entries run with keepalive ON and the load
# generators use keepalive by default.  Starlet defaults to
# max_keepalive_reqs => 1 (raised below) and Gazelle has no keepalive support
# at all, so its row pays a TCP setup+teardown per request - keep that in mind
# before reading the table as a like-for-like comparison.
#
# Usage: bash bench/compare.sh [duration] [connections] [threads]

cd "$(dirname "$0")/.."

DURATION=${1:-5}
CONNS=${2:-50}
THREADS=${3:-2}

# Prefer wrk, fallback to h2load
if command -v wrk >/dev/null 2>&1; then
    bench() { wrk -t$THREADS -c$CONNS -d${DURATION}s "http://127.0.0.1:$1/" 2>&1 | awk '/Requests\/sec/{print $2}'; }
elif command -v h2load >/dev/null 2>&1; then
    bench() { h2load --duration=${DURATION}s -c$CONNS -t$THREADS --h1 "http://127.0.0.1:$1/" 2>&1 | awk '/finished in/{print $4}'; }
else
    echo "Need wrk or h2load"; exit 1
fi

echo "=== Feersum vs Other Perl HTTP Servers ==="
echo "Config: ${DURATION}s, ${CONNS} connections, ${THREADS} threads"
echo ""

make -s 2>/dev/null

# run NAME PORT COMMAND...
# Stop a backgrounded server.  NB: bash sets SIGINT/SIGQUIT to SIG_IGN for
# &-backgrounded processes in a non-interactive script, so `kill -QUIT` is
# silently ignored and `wait` then blocks forever - which used to hang this
# script after its very first entry.  SIGTERM is not ignored; force-kill as a
# backstop and reap anything still holding the port.
stop_server() {
    local pid=$1 port=$2
    kill -TERM $pid 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill -KILL $pid 2>/dev/null
    wait $pid 2>/dev/null
    [ -n "$port" ] && fuser -k "$port"/tcp 2>/dev/null
    return 0
}

run() {
    local name=$1 port=$2; shift 2

    "$@" &
    local pid=$!
    sleep 2

    if ! curl -sf "http://127.0.0.1:$port/" >/dev/null 2>&1; then
        printf "  %-20s SKIP (not installed or failed to start)\n" "$name"
        stop_server $pid $port
        return
    fi

    local rps
    rps=$(bench "$port")
    printf "  %-20s %s req/s\n" "$name" "$rps"

    stop_server $pid $port
    sleep 1
}

HELLO='sub{[200,["Content-Type"=>"text/plain"],["Hello, World!"]]}'

run "Feersum native" 9201 perl -Iblib/lib -Iblib/arch -e '
    use Feersum; use EV; use IO::Socket::INET; use Socket qw(SOMAXCONN);
    my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1:9201",ReuseAddr=>1,Proto=>"tcp",Listen=>SOMAXCONN,Blocking=>0) or die;
    my $f=Feersum->new(); $f->use_socket($s); $f->set_keepalive(1);
    $f->request_handler(sub{$_[0]->send_response(200,["Content-Type"=>"text/plain"],\"Hello, World!")});
    EV::run()' 2>/dev/null

run "Feersum PSGI" 9202 perl -Iblib/lib -Iblib/arch -e '
    use Feersum; use EV; use IO::Socket::INET; use Socket qw(SOMAXCONN);
    my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1:9202",ReuseAddr=>1,Proto=>"tcp",Listen=>SOMAXCONN,Blocking=>0) or die;
    my $f=Feersum->new(); $f->use_socket($s); $f->set_keepalive(1);
    $f->psgi_request_handler('"$HELLO"');
    EV::run()' 2>/dev/null

run "Gazelle" 9203 \
    perl -e 'use Plack::Loader; Plack::Loader->load("Gazelle", port => 9203, max_workers => 1)->run('"$HELLO"')' 2>/dev/null

run "Starlet" 9204 \
    perl -e 'use Plack::Loader; Plack::Loader->load("Starlet", port => 9204, max_workers => 1, max_keepalive_reqs => 1000)->run('"$HELLO"')' 2>/dev/null

run "Twiggy" 9205 \
    perl -e 'use Plack::Loader; Plack::Loader->load("Twiggy", port => 9205)->run('"$HELLO"')' 2>/dev/null

run "Mojolicious" 9206 \
    perl -MMojolicious::Lite -e 'get "/" => sub{shift->render(text=>"Hello, World!")}; app->start("daemon","-l","http://127.0.0.1:9206","-m","production")' 2>/dev/null

echo ""
echo "Done."
