#!/bin/bash
# activate.sh — install-time Kiro engagement
# Runs immediately after containers start. Gets Kiro talking to the
# prospect while ERPNext initializes in the background.

IKUKU_DIR="/opt/ikuku"
KIRO_CLI=""
TOKEN=""
ENDPOINT=""

# --- Resolve kiro-cli location ---
if podman exec ikuku_frappe_1 test -f /home/frappe/.local/bin/kiro-cli 2>/dev/null; then
    KIRO_CLI="podman exec -it -e KIRO_API_KEY=\$KIRO_API_KEY ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli"
elif [ -f "$IKUKU_DIR/shared/kiro-cli" ]; then
    # Use host-side binary directly
    KIRO_CLI="$IKUKU_DIR/shared/kiro-cli"
    chmod +x "$IKUKU_DIR/shared/kiro-cli" 2>/dev/null
fi

# --- Write token + endpoint ---
mkdir -p "$IKUKU_DIR/.ikuku"
if [ -f "$IKUKU_DIR/ikuku.conf" ]; then
    ENDPOINT=$(grep -E '^AUTH_ENDPOINT=' "$IKUKU_DIR/ikuku.conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')
fi
ENDPOINT="${ENDPOINT:-${IKUKU_AUTH_ENDPOINT:-https://auth.next.skith.in}}"
echo "$ENDPOINT" > "$IKUKU_DIR/.ikuku/endpoint"

# Get token: from conf, from env, or from existing file
if [ -f "$IKUKU_DIR/.ikuku/token" ]; then
    TOKEN=$(cat "$IKUKU_DIR/.ikuku/token")
elif [ -f "$IKUKU_DIR/ikuku.conf" ]; then
    TOKEN=$(grep -E '^TOKEN=' "$IKUKU_DIR/ikuku.conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')
    if [ -n "$TOKEN" ]; then
        echo "$TOKEN" > "$IKUKU_DIR/.ikuku/token"
        chmod 600 "$IKUKU_DIR/.ikuku/token"
    fi
fi

# Try OTP registration if no token yet
if [ -z "$TOKEN" ] && [ -f "$IKUKU_DIR/ikuku.conf" ]; then
    CODES=$(grep -E '^ACTIVATION_CODE(S)?=' "$IKUKU_DIR/ikuku.conf" | tail -1 | cut -d= -f2 | tr -d ' \r')
    if [ -n "$CODES" ]; then
        MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || hostname | sha256sum | cut -d' ' -f1)
        INSTALL_ID="${IKUKU_INSTALL_ID:-ikuku-$(hostname)}"
        IFS=',' read -ra OTP_LIST <<< "$CODES"
        for OTP in "${OTP_LIST[@]}"; do
            OTP=$(echo "$OTP" | tr -d ' ')
            [ -z "$OTP" ] && continue
            RESULT=$(curl -sf "$ENDPOINT/register" -H "Content-Type: application/json" \
                -d "{\"otp\":\"$OTP\",\"machine_id\":\"$MACHINE_ID\",\"install_id\":\"$INSTALL_ID\"}" 2>/dev/null || echo "")
            TOKEN=$(echo "$RESULT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
            if [ -n "$TOKEN" ]; then
                echo "$TOKEN" > "$IKUKU_DIR/.ikuku/token"
                chmod 600 "$IKUKU_DIR/.ikuku/token"
                break
            fi
        done
    fi
fi

# --- Refresh token → KIRO_API_KEY ---
KIRO_API_KEY=""
if [ -n "$TOKEN" ]; then
    RESP=$(curl -sf "$ENDPOINT/refresh" -H "Content-Type: application/json" \
        -d "{\"token\":\"$TOKEN\"}" 2>/dev/null)
    KIRO_API_KEY=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get('kiro_api_key',''))" 2>/dev/null)
fi
export KIRO_API_KEY

if [ -z "$KIRO_API_KEY" ]; then
    echo ""
    echo "⚠  Kiro activation failed. ERPNext is still installing in the background."
    echo "   Check progress: podman logs -f ikuku_frappe_1"
    echo "   Once ready: http://localhost:8000 (Login: Administrator / admin)"
    echo ""
    echo "   To activate Kiro later, add your token to $IKUKU_DIR/.ikuku/token"
    echo ""
    # Fall back to tailing logs
    echo "--- Showing install progress (Ctrl+C to exit) ---"
    podman logs -f ikuku_frappe_1 2>&1
    exit 0
fi

# --- Write instructions for kiro-cli ---
mkdir -p "$IKUKU_DIR/.kiro"
cat > "$IKUKU_DIR/.kiro/instructions.md" << 'INSTRUCTIONS'
You are Kiro, an AI assistant helping a new user during their first ikuku (ERPNext) installation.

## Context
- ERPNext is currently installing in the background (bench init + app setup)
- This takes 5-10 minutes. You are here to engage the user productively while they wait.
- The user is likely a small business owner, commerce graduate, or reseller evaluating ERPNext.

## Your Job Right Now
1. Greet warmly. Acknowledge the install is happening.
2. Ask: "While we wait, what type of business are you thinking about for ERPNext?"
3. Based on their answer, have a natural conversation about their niche:
   - What do they sell? (products/services)
   - Who are their customers?
   - What's their biggest operational headache?
   - How do they handle inventory/billing today?
4. If they seem technical, explain what's being installed and why.
5. If they ask about progress, check the install log context and report honestly.

## When ERPNext is Ready
- It will be at http://localhost:8000 (Login: Administrator / admin)
- The bind-agent (AI assistant inside ERPNext) is at /app/bind-agent
- They can type `train` in this terminal later to start structured training

## Rules
- Be conversational, not robotic
- One question at a time
- Never say "I don't have access to..." — you're running locally, you have full access
- If they report an error, help troubleshoot (check podman logs, container status)
- Keep it light — this is their first impression of ikuku
INSTRUCTIONS

# --- Also inject token into container (for bind-agent once bench is ready) ---
podman exec --user root ikuku_frappe_1 bash -c "
    mkdir -p /workspace/.ikuku
    echo '$TOKEN' > /workspace/.ikuku/token
    echo '$ENDPOINT' > /workspace/.ikuku/endpoint
    chmod 600 /workspace/.ikuku/token
    chown 1000:1000 /workspace/.ikuku/token /workspace/.ikuku/endpoint
" 2>/dev/null &

# --- Launch kiro-cli ---
echo ""
echo "✨ Kiro AI activated. ERPNext is installing in the background."
echo "   (When ready, open http://localhost:8000)"
echo ""

cd "$IKUKU_DIR"
if [ -n "$KIRO_CLI" ] && echo "$KIRO_CLI" | grep -q "podman"; then
    # Run inside container
    podman exec -it \
        -e KIRO_API_KEY="$KIRO_API_KEY" \
        -w /opt/ikuku \
        ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli chat --trust-all-tools
else
    # Run host-side
    $KIRO_CLI chat --trust-all-tools
fi

# After kiro-cli exits, show status
echo ""
if curl -sf http://localhost:8000 > /dev/null 2>&1; then
    echo "✓ ERPNext is ready: http://localhost:8000"
    echo "  Login: Administrator / admin"
    echo "  Type 'train' to start structured training."
else
    echo "⏳ ERPNext is still setting up. Check: podman logs -f ikuku_frappe_1"
fi
