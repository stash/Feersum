#!/bin/bash
# Feersum TLS/H2 benchmark runner (using h2load)
#
# h2load speaks HTTP/2 over TLS by default.
# Use --h1 to force HTTP/1.1 over TLS.

cd "$(dirname "$0")/.."

DURATION=${1:-10}
CONNECTIONS=${2:-100}
THREADS=${3:-4}
CERT="eg/ssl-proxy/server.crt"
KEY="eg/ssl-proxy/server.key"

echo "========================================"
echo "Feersum TLS/H2 Benchmark (h2load)"
echo "Duration: ${DURATION}s, Connections: $CONNECTIONS, Threads: $THREADS"
echo "========================================"
echo

# Build first
make -s || exit 1

# Check TLS support
if ! perl -Iblib/lib -Iblib/arch -MFeersum -e 'Feersum->new->has_tls or die' 2>/dev/null; then
    echo "ERROR: Feersum not compiled with TLS support"
    exit 1
fi

# Check certs exist
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    echo "ERROR: Missing cert/key ($CERT / $KEY)"
    exit 1
fi

# Function to run benchmark
run_bench() {
    local name=$1
    local port=$2
    local cmd=$3
    local h2load_flags=$4
    local scheme=${5:-https}

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

    h2load --duration=${DURATION}s -c$CONNECTIONS -t$THREADS \
        $h2load_flags "${scheme}://127.0.0.1:$port/" 2>&1

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

# -- TLS + HTTP/1.1 ----------------------------------------------

run_bench "Native TLS HTTP/1.1" 5003 \
    "perl -Iblib/lib -Iblib/arch bench/native_tls.pl --port 5003" \
    "--h1"

run_bench "PSGI TLS HTTP/1.1" 5004 \
    "perl -Iblib/lib -Iblib/arch bench/psgi_server_tls.pl --port 5004" \
    "--h1"

# -- TLS + HTTP/2 ------------------------------------------------

run_bench "Native TLS H2" 5003 \
    "perl -Iblib/lib -Iblib/arch bench/native_tls.pl --port 5003 --h2" \
    ""

run_bench "PSGI TLS H2" 5004 \
    "perl -Iblib/lib -Iblib/arch bench/psgi_server_tls.pl --port 5004 --h2" \
    ""

# -- TLS + H2 prefork --------------------------------------------

run_bench "Native TLS H2 (prefork=2)" 5003 \
    "perl -Iblib/lib -Iblib/arch bench/native_tls_prefork.pl --port 5003 --workers 2 --h2" \
    ""

# -- Comparison: plain HTTP/1.1 (no TLS) -------------------------

run_bench "Native plain HTTP/1.1 (baseline)" 5005 \
    "perl -Iblib/lib -Iblib/arch bench/native.pl 5005" \
    "--h1" \
    "http"

echo "========================================"
echo "TLS/H2 Benchmark complete"
echo "========================================"
