#!/bin/bash
# Generate self-signed SSL certificate for testing
cd "$(dirname "$0")"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server.key -out server.crt \
    -days 3650 -subj "/CN=localhost" \
    2>/dev/null

echo "Generated: server.key, server.crt"
