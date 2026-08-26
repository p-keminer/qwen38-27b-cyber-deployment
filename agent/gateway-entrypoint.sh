#!/bin/sh
set -eu

required_file() {
    if [ ! -f "$1" ]; then
        echo "Required gateway secret file is missing: $1" >&2
        exit 1
    fi
}

required_file /run/secrets/ssh_identity
required_file /run/secrets/known_hosts
required_file /run/secrets/model_api_key

case "${RUNPOD_SSH_HOST:-}" in
    ''|*[!A-Za-z0-9.-]*) echo 'RUNPOD_SSH_HOST is invalid.' >&2; exit 1 ;;
esac
case "${RUNPOD_SSH_USER:-}" in
    ''|*[!A-Za-z0-9_-]*) echo 'RUNPOD_SSH_USER is invalid.' >&2; exit 1 ;;
esac
case "${RUNPOD_SSH_PORT:-}" in
    ''|*[!0-9]*) echo 'RUNPOD_SSH_PORT is invalid.' >&2; exit 1 ;;
esac
case "${RUNPOD_REMOTE_PORT:-}" in
    ''|*[!0-9]*) echo 'RUNPOD_REMOTE_PORT is invalid.' >&2; exit 1 ;;
esac

model_api_key="$(tr -d '\r\n' < /run/secrets/model_api_key)"
case "$model_api_key" in
    ''|*[!A-Za-z0-9_-]*) echo 'The model API key has an invalid format.' >&2; exit 1 ;;
esac

install -o root -g root -m 0600 /run/secrets/ssh_identity /tmp/ssh_identity
install -o root -g root -m 0600 /run/secrets/known_hosts /tmp/known_hosts

cat > /tmp/nginx.conf <<EOF
user root;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 256;
}

http {
    access_log off;
    client_max_body_size 25m;

    server {
        listen 18081;

        location / {
            proxy_pass http://127.0.0.1:18080;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_connect_timeout 15s;
            # Long-lived interactive-v1 streams are context-owned. These are
            # idle transport guards, not a request wall-clock deadline.
            proxy_read_timeout 7d;
            proxy_send_timeout 7d;
            proxy_set_header Connection "";
            proxy_set_header Authorization "Bearer ${model_api_key}";
        }
    }
}
EOF

ssh \
    -N -T \
    -F /dev/null \
    -p "$RUNPOD_SSH_PORT" \
    -i /tmp/ssh_identity \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile=/tmp/known_hosts \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ForwardAgent=no \
    -L "127.0.0.1:18080:127.0.0.1:${RUNPOD_REMOTE_PORT}" \
    "${RUNPOD_SSH_USER}@${RUNPOD_SSH_HOST}" &
ssh_pid=$!

cleanup() {
    kill "$ssh_pid" ${nginx_pid:-} 2>/dev/null || true
    wait "$ssh_pid" ${nginx_pid:-} 2>/dev/null || true
}
trap cleanup EXIT INT TERM

attempt=0
until nc -z 127.0.0.1 18080; do
    if ! kill -0 "$ssh_pid" 2>/dev/null; then
        wait "$ssh_pid"
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
        echo 'SSH tunnel did not become ready.' >&2
        exit 1
    fi
    sleep 1
done

nginx -c /tmp/nginx.conf -g 'daemon off;' &
nginx_pid=$!

while kill -0 "$ssh_pid" 2>/dev/null && kill -0 "$nginx_pid" 2>/dev/null; do
    sleep 2
done
exit 1
