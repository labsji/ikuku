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

# --- Read the prospect's niche facts from ikuku.conf (baked by the reseller/evalkit) ---
PROSPECT_NAME=$(grep -E '^PROSPECT_NAME=' "$IKUKU_DIR/ikuku.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')
INDUSTRY=$(grep -E '^INDUSTRY=' "$IKUKU_DIR/ikuku.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')
COUNTRY=$(grep -E '^COUNTRY=' "$IKUKU_DIR/ikuku.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')
PROSPECT_NAME="${PROSPECT_NAME:-your business}"

# --- Write instructions for kiro-cli ---
# IMPORTANT: Kiro ALREADY KNOWS who the prospect is (from the evalkit). It must NOT
# ask "what business are you running" — it greets them by name and proposes setup for
# their specific industry. The rich niche brief (niche-context.md) is appended below.
mkdir -p "$IKUKU_DIR/.kiro"
cat > "$IKUKU_DIR/.kiro/instructions.md" << INSTRUCTIONS
You are Kiro, an AI development/ops agent running in this prospect's terminal, acting
as the guide for their preconfigured ERPNext. Be direct, honest, and genuinely useful.

## Who this prospect is (you already know this — do NOT ask)
- Business: ${PROSPECT_NAME}
- Industry: ${INDUSTRY:-(see the brief below)}
- Country: ${COUNTRY:-(see the brief below)}
A detailed business brief is at the end of this file ("Prospect Business Brief").
Read it and reflect their actual business back to them so they feel understood.

## Your Environment
- ERPNext: http://localhost:8000 (Login: Administrator / admin) — already installed and seeded for this prospect
- bind-agent (AI inside ERPNext): http://localhost:8000/app/bind-agent
- Tray app files (you may write these, and tell the user when you do):
  - /mnt/c/ikuku/tray-config.json  (menu/brand personalization)
  - /mnt/c/ikuku/notification.txt  (balloon tips)
  - /mnt/c/ikuku/status.txt        (read: system state)
- Container logs: podman logs ikuku_frappe_1

## First: verify, don't assume
Run: curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/
- 200 => ERPNext is live; greet with confidence.
- else => it's still starting; say so plainly and engage while it comes up.

## Your job (niche-aware — this is ${PROSPECT_NAME}, ${INDUSTRY})
1. Greet them BY NAME and show you understand their business (use the brief).
2. Confirm ERPNext is live at localhost:8000.
3. Propose 2-3 concrete, industry-specific next steps for THEIR business
   (e.g. the DocTypes/records that matter for ${INDUSTRY}) — offer to set them up.
4. Personalize their tray menu for their business by writing tray-config.json
   (brand = "${PROSPECT_NAME}"), and tell them what you changed.
5. Help them create their first real records and explore ERPNext.
6. When they're ready, suggest \`train\` for structured tutorials.

## How you work
- Be conversational, one step at a time.
- You have real shell + ERPNext access — use it. But be HONEST: if something can't
  be reached or a command fails, say so plainly and diagnose it (podman ps, logs, curl).
  Never pretend. Never invent business facts (prices, dates) — those come from their data.
- Show the user any file you write to their system and why.

## Tray integration
- tray-config.json -> menu updates live; notification.txt -> balloon tip; status.txt -> state.
INSTRUCTIONS

# Append the rich niche brief so Kiro knows the prospect's actual business.
if [ -f "$IKUKU_DIR/niche-context.md" ]; then
    {
        echo ""
        echo "## Prospect Business Brief"
        echo ""
        cat "$IKUKU_DIR/niche-context.md"
    } >> "$IKUKU_DIR/.kiro/instructions.md"
fi

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
    # Copy instructions into container and fix permissions
    podman exec --user root ikuku_frappe_1 bash -c "mkdir -p /home/frappe/.kiro; chown -R frappe:frappe /home/frappe/.kiro" 2>/dev/null
    podman cp "$IKUKU_DIR/.kiro/instructions.md" ikuku_frappe_1:/home/frappe/.kiro/instructions.md 2>/dev/null
    podman exec --user root ikuku_frappe_1 chown frappe:frappe /home/frappe/.kiro/instructions.md 2>/dev/null
    # Run inside container with initial greeting prompt
    podman exec -it \
        -e KIRO_API_KEY="$KIRO_API_KEY" \
        -w /home/frappe \
        ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli chat --trust-all-tools \
        "Read .kiro/instructions.md now, including the Prospect Business Brief at the end. You already know this prospect is ${PROSPECT_NAME} (${INDUSTRY}) - do NOT ask what business they run. Verify ERPNext (curl localhost:8000), then greet ${PROSPECT_NAME} by name, reflect back their actual business from the brief, and propose concrete ${INDUSTRY}-specific next steps in their ERPNext."
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
