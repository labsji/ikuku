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

# Try kiro-cli
if which kiro-cli >/dev/null 2>&1; then
    exec kiro-cli chat --trust-all-tools
elif podman exec ikuku_frappe_1 ls /home/frappe/.local/bin/kiro-cli >/dev/null 2>&1; then
    exec podman exec -it -w /home/frappe/next-sale ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli chat --trust-all-tools
else
    echo "⚠ Kiro CLI not available. Listing tutorials:"
    ls tutorials/
    echo ""
    echo "Start with: cat tutorials/01-recap-erpnext.md"
fi
