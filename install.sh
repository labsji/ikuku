#!/bin/bash
# install.sh - ikuku installer for Linux and macOS
# Usage: bash install.sh [--apps wiki,lms,erpnext]
set -e

APPS="wiki"
INSTALL_DIR="$HOME/.ikuku"
PORT=8000

while [[ $# -gt 0 ]]; do
    case $1 in
        --apps) APPS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "=== ikuku: Installing Frappe apps ==="
echo "Apps: $APPS | Port: $PORT"

# Detect container runtime
if command -v podman &>/dev/null; then
    RUNTIME=podman
    COMPOSE="podman-compose"
elif command -v docker &>/dev/null; then
    RUNTIME=docker
    COMPOSE="docker compose"
else
    echo "Error: podman or docker required."
    echo "  macOS:  brew install podman"
    echo "  Ubuntu: sudo apt install podman podman-compose"
    echo "  Fedora: sudo dnf install podman podman-compose"
    exit 1
fi

# Check compose
if ! command -v $COMPOSE &>/dev/null && [ "$RUNTIME" = "podman" ]; then
    echo "Error: podman-compose required. Install: pip install podman-compose"
    exit 1
fi

echo "Using: $RUNTIME"

# Setup install dir
mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/init.sh" "$INSTALL_DIR/"

cd "$INSTALL_DIR"

# Set apps and port
export IKUKU_APPS="$APPS"
sed -i.bak "s/8000:8000/$PORT:8000/" docker-compose.yml 2>/dev/null || \
    sed -i '' "s/8000:8000/$PORT:8000/" docker-compose.yml  # macOS sed

# Start
echo "Starting containers..."
$COMPOSE up -d

echo ""
echo "=== ikuku is starting ==="
echo "This takes a few minutes on first run (building bench + installing apps)."
echo ""
echo "  Demo site: http://localhost:$PORT        (pre-loaded demo data)"
echo "  MVP site:  http://localhost:$((PORT+1))   (blank — build here)"
echo "  Login:     Administrator / admin"
echo ""
echo "Follow progress: $COMPOSE logs -f frappe"
echo "Stop:            cd $INSTALL_DIR && $COMPOSE down"
echo "Uninstall:       rm -rf $INSTALL_DIR"
