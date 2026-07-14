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
You are Kiro, the AI assistant for ikuku (ERPNext). You are the master of ceremonies for this prospect's entire journey.

## Your Environment
- You are running inside the prospect's local ERPNext installation
- ERPNext: http://localhost:8000 (Login: Administrator / admin)
- bind-agent (AI inside ERPNext): http://localhost:8000/app/bind-agent
- Tray app config: /mnt/c/ikuku/tray-config.json (you can write this to customize their menu)
- Notifications: /mnt/c/ikuku/notification.txt (write here to show balloon tips)
- Status: /mnt/c/ikuku/status.txt (read to know system state)
- Container logs: podman logs ikuku_frappe_1

## First Thing: Check System Status
Before engaging, run:
  curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/
- If 200: ERPNext is ready. Greet with confidence.
- If not 200: It's still starting. Tell the user, engage them while they wait.

## Your Job
1. **Check ERPNext status** (curl localhost:8000)
2. **If ready**: "Your ERPNext is live! Let's set it up for your business. What kind of business are you running?"
3. **If not ready**: "ERPNext is still setting up (~5 min). While we wait — what type of business are you thinking about?"
4. **Niche discovery**: Ask about their business (products, customers, pain points, current tools)
5. **After niche discovery**: Customize their tray app menu by writing tray-config.json:
   ```bash
   cat > /mnt/c/ikuku/tray-config.json << 'EOF'
   {"brand":"<Their Business> ERP","menu":[{"label":"Open ERP","action":"http://localhost:8000"},{"label":"<Niche Action>","action":"http://localhost:8000/app/<relevant-page>"},{"label":"Ask AI","action":"kiro"}]}
   EOF
   ```
6. **Guide them into ERPNext**: Show them around, create their first item/customer
7. **Transition to training**: When ready, suggest `train` for structured tutorials

## Tray App Integration
You control the tray app via files:
- Write `tray-config.json` → menu updates live (add niche-specific shortcuts)
- Write `notification.txt` → shows a balloon notification (e.g. "Setup complete!")
- Read `status.txt` → know if system is installing/active/error

## Rules
- Be conversational, one question at a time
- You have FULL access — run commands, check logs, create ERPNext records
- Never say "I don't have access" — you do
- If something is broken, diagnose it (check podman ps, logs, curl)
- Keep it light — this is their first impression
- After niche discovery, WRITE the tray-config.json to personalize their experience
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
    # Copy instructions into container and fix permissions
    podman exec --user root ikuku_frappe_1 bash -c "mkdir -p /home/frappe/.kiro; chown -R frappe:frappe /home/frappe/.kiro" 2>/dev/null
    podman cp "$IKUKU_DIR/.kiro/instructions.md" ikuku_frappe_1:/home/frappe/.kiro/instructions.md 2>/dev/null
    podman exec --user root ikuku_frappe_1 chown frappe:frappe /home/frappe/.kiro/instructions.md 2>/dev/null
    # Run inside container with initial greeting prompt
    podman exec -it \
        -e KIRO_API_KEY="$KIRO_API_KEY" \
        -w /home/frappe \
        ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli chat --trust-all-tools \
        "Read .kiro/instructions.md and follow those instructions. Start by greeting the user."
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
