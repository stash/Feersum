#!/bin/bash
# Feersum Unix socket benchmark runner (using h2load)

cd "$(dirname "$0")/.."

DURATION=${1:-10}
CONNECTIONS=${2:-50}
THREADS=${3:-4}
SOCKET_PATH="/tmp/feersum_bench.sock"

echo "========================================"
echo "Feersum Unix Socket Benchmark (h2load)"
echo "Duration: ${DURATION}s, Connections: $CONNECTIONS, Threads: $THREADS"
echo "========================================"
echo

# Build first
make -s || exit 1

# Function to run benchmark
run_bench() {
    local name=$1
    local server_cmd=$2
    local keepalive=${3:-1}

    echo "--- $name ---"

    # Kill any existing server using the socket
    if [ -S "$SOCKET_PATH" ]; then
        fuser -k "$SOCKET_PATH" 2>/dev/null
        rm -f "$SOCKET_PATH"
    fi
    sleep 0.3

    # Start server in background
    $server_cmd &
    local pid=$!
    sleep 0.5

    # Check if server started
    if ! kill -0 $pid 2>/dev/null; then
        echo "Failed to start server"
        return 1
    fi

    # Check if socket exists
    if [ ! -S "$SOCKET_PATH" ]; then
        echo "Socket not created"
        kill -TERM $pid 2>/dev/null; kill -KILL $pid 2>/dev/null
        return 1
    fi

    # Run h2load with Unix socket (with or without keepalive)
    if [ "$keepalive" = "1" ]; then
        h2load --duration=${DURATION}s -c$CONNECTIONS -t$THREADS --h1 -B "unix:$SOCKET_PATH" "http://localhost/" 2>&1
    else
        h2load --duration=${DURATION}s -c$CONNECTIONS -t$THREADS --h1 -H "Connection: close" -B "unix:$SOCKET_PATH" "http://localhost/" 2>&1
    fi

    # Stop server. NB: bash sets SIGINT/SIGQUIT to SIG_IGN for &-backgrounded
    # processes in a non-interactive script, so `kill -QUIT` is silently ignored
    # and `wait` would hang forever. SIGTERM is not ignored; force-kill as backup.
    kill -TERM $pid 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill -KILL $pid 2>/dev/null
    wait $pid 2>/dev/null
    fuser -k "$SOCKET_PATH" 2>/dev/null  # reap prefork workers still holding the socket
    rm -f "$SOCKET_PATH"
    sleep 0.3

    echo
}

# Native benchmarks
run_bench "Native (keepalive)" \
    "perl -Iblib/lib -Iblib/arch bench/native_unix.pl --socket $SOCKET_PATH --keepalive" 1

run_bench "Native (no keepalive)" \
    "perl -Iblib/lib -Iblib/arch bench/native_unix.pl --socket $SOCKET_PATH --no-keepalive" 0

# PSGI benchmarks
run_bench "PSGI (keepalive)" \
    "perl -Iblib/lib -Iblib/arch bench/psgi_server_unix.pl --socket $SOCKET_PATH --keepalive" 1

run_bench "PSGI (no keepalive)" \
    "perl -Iblib/lib -Iblib/arch bench/psgi_server_unix.pl --socket $SOCKET_PATH --no-keepalive" 0

echo "========================================"
echo "Unix Socket Benchmark complete"
echo "========================================"
