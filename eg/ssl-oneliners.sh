#!/bin/bash
# SSL termination one-liners for Feersum
# Backend: plackup -s Feersum -p 5000 --keepalive=1 app.psgi
# Backend: plackup -s Feersum -l /tmp/feersum.sock --keepalive=1 app.psgi

### Generate test certificates
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=localhost"
cat cert.pem key.pem > server.pem
# Or use mkcert for trusted local certs: mkcert -cert-file cert.pem -key-file key.pem localhost

### socat
socat OPENSSL-LISTEN:443,cert=server.pem,verify=0,fork,reuseaddr TCP:127.0.0.1:5000
socat OPENSSL-LISTEN:443,cert=server.pem,verify=0,fork,reuseaddr UNIX:/tmp/feersum.sock

### stunnel
stunnel3 -d 443 -r 127.0.0.1:5000 -p server.pem
stunnel3 -d 443 -r /tmp/feersum.sock -p server.pem

### Caddy
caddy reverse-proxy --from :443 --to localhost:5000
caddy reverse-proxy --from :443 --to unix//tmp/feersum.sock

### haproxy (minimal)
haproxy -f- <<'EOF'
defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
frontend https
    bind *:443 ssl crt server.pem
    default_backend feersum
backend feersum
    server app 127.0.0.1:5000
EOF

### haproxy (unix socket)
haproxy -f- <<'EOF'
defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
frontend https
    bind *:443 ssl crt server.pem
    default_backend feersum
backend feersum
    server app /tmp/feersum.sock
EOF

### nginx stream
nginx -c /dev/stdin <<'EOF'
events { worker_connections 1024; }
stream {
    server {
        listen 443 ssl;
        ssl_certificate cert.pem;
        ssl_certificate_key key.pem;
        proxy_pass 127.0.0.1:5000;
    }
}
EOF

### nginx stream (unix socket)
nginx -c /dev/stdin <<'EOF'
events { worker_connections 1024; }
stream {
    upstream backend { server unix:/tmp/feersum.sock; }
    server {
        listen 443 ssl;
        ssl_certificate cert.pem;
        ssl_certificate_key key.pem;
        proxy_pass backend;
    }
}
EOF
