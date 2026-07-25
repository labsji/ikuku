#!/bin/bash
# start-local.sh — launched by the `train` alias
# Works from any Windows user's WSL session.

IKUKU_DIR="/opt/ikuku"
REPO_DIR="$HOME/next-sale"

# Find the bundle - check multiple locations
find_bundle() {
    # In the ikuku install dir
    [ -f "$IKUKU_DIR/shared/next-sale.bundle" ] && echo "$IKUKU_DIR/shared/next-sale.bundle" && return
    # On the Windows drive (any user's ikuku folder)
    for userdir in /mnt/c/Users/*/ikuku/shared; do
        [ -f "$userdir/next-sale.bundle" ] && echo "$userdir/next-sale.bundle" && return
    done
    # In Program Files
    [ -f "/mnt/c/Program Files/ikuku/shared/next-sale.bundle" ] && echo "/mnt/c/Program Files/ikuku/shared/next-sale.bundle" && return
    echo ""
}

# Clone training content if not present
if [ ! -d "$REPO_DIR" ]; then
    BUNDLE=$(find_bundle)
    if [ -n "$BUNDLE" ]; then
        echo "Setting up training content..."
        git clone "$BUNDLE" "$REPO_DIR" 2>/dev/null
        cd "$REPO_DIR" && git checkout tutor-main 2>/dev/null || true
    else
        echo "❌ Training content not found. Is ikuku installed?"
        echo "   Looking for next-sale.bundle in $IKUKU_DIR/shared/"
        exit 1
    fi
fi

cd "$REPO_DIR"
echo "📚 Training tutorials ready: $REPO_DIR/tutorials/"
echo "🌐 ERPNext at: http://localhost:8000 (Login: Administrator / admin)"
echo ""

# Write Kiro instructions so it knows to start in training mode
mkdir -p .kiro
cat > .kiro/instructions.md << 'INSTRUCTIONS'
You are a reseller training assistant for ERPNext. You are running inside an ikuku local installation.

## Context
- ERPNext instance: http://localhost:8000 (Login: Administrator / admin)
- Training tutorials: ./tutorials/ (01 through 09)
- Student's progress: ./PROGRESS.md
- ERPNext is ALREADY RUNNING locally. Do NOT ask about deployment, servers, or infrastructure.

## On Start
Begin immediately with the Reseller Niche Discovery conversation. Do NOT ask setup questions — everything is ready.
1. Greet warmly, then ask: "What type of small business would you like to focus on as your niche?"
2. Once they answer, ask 5-7 questions about that business (customers, products, pain points, pricing model)
3. Produce a "Niche Training Brief" card summarizing their answers
4. Ask for approval, then transition to Tutorial 1

## Rules
- One question at a time, conversational tone
- NEVER ask about infrastructure, deployment, servers, or setup — it's all done
- Adapt all tutorial content to the student's chosen niche
- Replace any remote ERPNext URL references with http://localhost:8000
- Track progress in PROGRESS.md (git commit after each tutorial)
- You are teaching a commerce graduate who is new to ERPNext
INSTRUCTIONS

# Try kiro-cli
# Refresh token → KIRO_API_KEY for headless access
KIRO_API_KEY=""
TOKEN_FILE="/opt/ikuku/.ikuku/token"
ENDPOINT_FILE="/opt/ikuku/.ikuku/endpoint"
DEFAULT_AUTH_ENDPOINT="${IKUKU_AUTH_ENDPOINT:-https://auth.next.skith.in}"
if [ -f "$TOKEN_FILE" ]; then
    ENDPOINT=$(cat "$ENDPOINT_FILE" 2>/dev/null || echo "$DEFAULT_AUTH_ENDPOINT")
    TOKEN=$(cat "$TOKEN_FILE")
    KIRO_API_KEY=$(curl -sf "$ENDPOINT/refresh" -H "Content-Type: application/json" \
        -d "{\"token\":\"$TOKEN\"}" 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin).get('kiro_api_key',''))" 2>/dev/null || echo "")
fi
export KIRO_API_KEY

# Inject niche-pattern context if available (CMMN case context)
if [ -f "$REPO_DIR/niche-pattern.md" ]; then
    cat >> .kiro/instructions.md << 'PATTERN_CTX'

## Niche Pattern Context
Read niche-pattern.md for the case management context of this reseller's niche.
Use it to guide tutorial delivery and adapt exercises to their specific vertical pattern.
PATTERN_CTX
fi

if which kiro-cli >/dev/null 2>&1; then
    kiro-cli chat --trust-all-tools
elif podman exec ikuku_frappe_1 ls /home/frappe/.local/bin/kiro-cli >/dev/null 2>&1; then
    podman exec -it -e KIRO_API_KEY="$KIRO_API_KEY" -w /home/frappe/next-sale ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli chat --trust-all-tools
else
    echo "⚠ Kiro CLI not available. Listing tutorials:"
    ls tutorials/
    echo ""
    echo "Start with: cat tutorials/01-recap-erpnext.md"
fi

# After kiro exits, stay in the training repo
cd "$REPO_DIR" 2>/dev/null
echo ""
echo "Training session ended. You're in: $REPO_DIR"
echo "Type 'train' to resume, or explore tutorials/ manually."
