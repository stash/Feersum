#!/bin/bash
# Feersum benchmark runner (using h2load)

cd "$(dirname "$0")/.."

DURATION=${1:-10}
CONNECTIONS=${2:-100}
THREADS=${3:-4}

echo "========================================"
echo "Feersum Benchmark (h2load)"
echo "Duration: ${DURATION}s, Connections: $CONNECTIONS, Threads: $THREADS"
echo "========================================"
echo

# Build first
make -s || exit 1

# Function to run benchmark
run_bench() {
    local name=$1
    local port=$2
    local cmd=$3
    local keepalive=${4:-1}

    echo "--- $name ---"

    # Kill any existing process on the port
    fuser -k $port/tcp 2>/dev/null
    sleep 0.5

    # Start server in background
    $cmd &
    local pid=$!
    sleep 1

    # Check if server started
    if ! kill -0 $pid 2>/dev/null; then
        echo "Failed to start server"
        return 1
    fi

    # Run h2load (with or without keepalive)
    if [ "$keepalive" = "1" ]; then
        h2load --duration=${DURATION}s -c$CONNECTIONS -t$THREADS --h1 "http://127.0.0.1:$port/" 2>&1
    else
        h2load --duration=${DURATION}s -c$CONNECTIONS -t$THREADS --h1 -H "Connection: close" "http://127.0.0.1:$port/" 2>&1
    fi

    # Stop server. NB: bash sets SIGINT/SIGQUIT to SIG_IGN for &-backgrounded
    # processes in a non-interactive script, so `kill -QUIT` is silently ignored
    # and `wait` would hang forever. SIGTERM is not ignored; force-kill as backup.
    kill -TERM $pid 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill -KILL $pid 2>/dev/null
    wait $pid 2>/dev/null
    fuser -k $port/tcp 2>/dev/null  # reap prefork workers still holding the port
    sleep 0.5

    echo
}

# Benchmark PSGI app (with keep-alive)
run_bench "PSGI App (keep-alive)" 5000 "perl -Iblib/lib -Iblib/arch bench/psgi_server.pl --port 5000 --keepalive" 1

# Benchmark PSGI app (no keep-alive)
run_bench "PSGI App (no keep-alive)" 5000 "perl -Iblib/lib -Iblib/arch bench/psgi_server.pl --port 5000" 0

# Benchmark PSGI app with prefork
run_bench "PSGI App (prefork=2)" 5000 "perl -Iblib/lib -Iblib/arch bench/psgi_server_prefork.pl --port 5000 --workers 2 --keepalive" 1

# Benchmark Native app (with keep-alive)
run_bench "Native App (keep-alive)" 5002 "perl -Iblib/lib -Iblib/arch bench/native.pl 5002" 1

# Benchmark Native app (no keep-alive)
run_bench "Native App (no keep-alive)" 5002 "perl -Iblib/lib -Iblib/arch bench/native.pl 5002" 0

# Benchmark Native app with prefork
run_bench "Native App (prefork=2)" 5002 "perl -Iblib/lib -Iblib/arch bench/native_prefork.pl 5002 2" 1

echo "========================================"
echo "Benchmark complete"
echo "========================================"
