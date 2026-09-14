#!/bin/bash
# init.sh - PROSPECT fast-path: bench is already built in the frappe-bench volume.
# This ONLY starts the pre-built bench + does Kiro activation. It NEVER rebuilds
# (rebuild would take ~30 min; the whole point of the pre-built tar is instant start).

cd /home/frappe/frappe-bench || { echo "no frappe-bench"; sleep infinity; }

# Point hosts at the compose service names (they resolve via the pod's DNS)
bench set-mariadb-host mariadb 2>/dev/null || true
bench set-redis-cache-host redis://redis:6379 2>/dev/null || true
bench set-redis-queue-host redis://redis:6379 2>/dev/null || true
bench set-redis-socketio-host redis://redis:6379 2>/dev/null || true

SITE="ikuku.localhost"
# Ensure a current site so `bench start`/serve targets it
echo "$SITE" > sites/currentsite.txt 2>/dev/null || true
bench use "$SITE" 2>/dev/null || true

# Wait for mariadb to accept connections (DNS + service ready)
for i in $(seq 1 60); do
    env/bin/python -c "import MySQLdb; MySQLdb.connect(host='mariadb',user='root',passwd='123')" 2>/dev/null && break
    sleep 2
done

# Wait for redis to resolve+respond
for i in $(seq 1 30); do
    python3 -c "import socket; socket.gethostbyname('redis')" 2>/dev/null && break
    sleep 2
done

# --- Kiro layer: refresh kiro-cli + bind from /workspace/shared (idempotent) ---
if [ -f /workspace/shared/kiro-cli ]; then
    mkdir -p /home/frappe/.local/bin
    cp /workspace/shared/kiro-cli /home/frappe/.local/bin/kiro-cli
    cp /workspace/shared/kiro-cli-chat /home/frappe/.local/bin/kiro-cli-chat 2>/dev/null || true
    chmod +x /home/frappe/.local/bin/kiro-cli /home/frappe/.local/bin/kiro-cli-chat 2>/dev/null || true
fi

# --- Kiro activation (headless, idempotent - only if no token yet) ---
mkdir -p /workspace/.ikuku /home/frappe/.ikuku
if [ -f /workspace/ikuku.conf ]; then
    AUTH_ENDPOINT=$(grep -E '^AUTH_ENDPOINT=' /workspace/ikuku.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')
    AUTH_ENDPOINT="${AUTH_ENDPOINT:-${IKUKU_AUTH_ENDPOINT:-https://auth.next.skith.in}}"
    echo "$AUTH_ENDPOINT" > /workspace/.ikuku/endpoint
    if [ ! -f /workspace/.ikuku/token ]; then
        CODES=$(grep -E '^ACTIVATION_CODE(S)?=' /workspace/ikuku.conf | tail -1 | cut -d= -f2 | tr -d ' \r')
        if [ -n "$CODES" ]; then
            MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || hostname | sha256sum | cut -d' ' -f1)
            INSTALL_ID=$(grep -E '^INSTALL_ID=' /workspace/ikuku.conf | tail -1 | cut -d= -f2 | tr -d ' \r')
            INSTALL_ID="${INSTALL_ID:-ikuku-$(hostname)}"
            IFS=',' read -ra OTP_LIST <<< "$CODES"
            for OTP in "${OTP_LIST[@]}"; do
                OTP=$(echo "$OTP" | tr -d ' ')
                [ -z "$OTP" ] && continue
                RESULT=$(curl -sf "$AUTH_ENDPOINT/register" -H "Content-Type: application/json" \
                    -d "{\"otp\":\"$OTP\",\"machine_id\":\"$MACHINE_ID\",\"install_id\":\"$INSTALL_ID\"}" 2>/dev/null || echo "")
                TOKEN=$(echo "$RESULT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
                if [ -n "$TOKEN" ]; then
                    echo "$TOKEN" > /workspace/.ikuku/token
                    chmod 600 /workspace/.ikuku/token
                    echo "Kiro activated"
                    break
                fi
            done
        fi
    fi
fi
[ -f /workspace/.ikuku/token ] && ln -sf /workspace/.ikuku/token /home/frappe/.ikuku/token 2>/dev/null
[ -f /workspace/.ikuku/endpoint ] && ln -sf /workspace/.ikuku/endpoint /home/frappe/.ikuku/endpoint 2>/dev/null

echo "ready" > /workspace/status.txt 2>/dev/null
echo "Starting bench..."
bench start
