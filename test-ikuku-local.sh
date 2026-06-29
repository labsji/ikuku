#!/bin/bash
# test-ikuku-local.sh — Test ikuku kiro-layer init.sh on Linux (CloudShell/EC2)
# Mirrors what happens inside the Windows WSL container, without needing Windows.
#
# Usage:
#   bash test-ikuku-local.sh              # test full init (takes ~10min first time)
#   bash test-ikuku-local.sh activate     # test only activation flow
#   bash test-ikuku-local.sh quick        # skip bench init, test kiro+bind only
#
# Prerequisites: podman or docker installed (CloudShell has docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="ikuku-test"
IKUKU_DIR="/tmp/ikuku-workspace"
MODE="${1:-full}"

# Prepare workspace (same layout as Windows install)
mkdir -p "$IKUKU_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/init.sh" "$IKUKU_DIR/"
[ -f "$SCRIPT_DIR/ikuku.conf" ] && cp "$SCRIPT_DIR/ikuku.conf" "$IKUKU_DIR/"
tr -d '\r' < "$IKUKU_DIR/init.sh" > "$IKUKU_DIR/init.sh.tmp" && mv "$IKUKU_DIR/init.sh.tmp" "$IKUKU_DIR/init.sh"
echo "IKUKU_APPS=erpnext" > "$IKUKU_DIR/.env"

# Use podman if available, else docker
CTR=$(command -v podman 2>/dev/null || command -v docker)
echo "Using: $CTR"
echo "Workspace: $IKUKU_DIR"

case "$MODE" in
  activate)
    # Test just the activation section — no bench, no mariadb needed
    echo "=== Testing activation flow ==="
    $CTR run --rm \
      -v "$IKUKU_DIR:/workspace" \
      --name "$CONTAINER_NAME" \
      ubuntu:24.04 bash -c '
        apt-get update -qq && apt-get install -y -qq curl python3 > /dev/null 2>&1
        export HOME=/home/frappe
        mkdir -p /home/frappe
        # Extract and run just the activation section from init.sh
        sed -n "/^# --- Kiro activation/,/^fi$/p" /workspace/init.sh | bash
        echo "---"
        echo "Token file:"
        cat /home/frappe/.ikuku/token 2>/dev/null || echo "(none)"
      '
    ;;

  quick)
    # Test kiro-cli install + bind extraction (no bench/erpnext)
    echo "=== Quick test: kiro + bind install ==="
    $CTR run --rm \
      -v "$IKUKU_DIR:/workspace" \
      --name "$CONTAINER_NAME" \
      ubuntu:24.04 bash -c '
        apt-get update -qq && apt-get install -y -qq curl python3 > /dev/null 2>&1
        echo "--- Testing kiro-cli download ---"
        curl -sfL "https://ikuku-releases.s3.ap-south-1.amazonaws.com/kiro/kiro-cli" -o /usr/local/bin/kiro-cli && chmod +x /usr/local/bin/kiro-cli && kiro-cli --version || echo "KIRO DOWNLOAD FAILED (expected without public S3)"
        echo "--- Testing bind extraction ---"
        curl -sfL "https://ikuku-releases.s3.ap-south-1.amazonaws.com/bind/bind.tar.gz" -o /tmp/bind.tar.gz && mkdir -p /opt/bind && cd /opt/bind && tar xzf /tmp/bind.tar.gz && ls bind/denote/notebook_app.py && echo "BIND OK" || echo "BIND DOWNLOAD FAILED (expected without public S3)"
        echo "--- Testing activation ---"
        export HOME=/home/frappe; mkdir -p /home/frappe
        sed -n "/^# --- Kiro activation/,/^fi$/p" /workspace/init.sh | bash
      '
    ;;

  full)
    # Full test — needs mariadb + redis (use compose)
    echo "=== Full test: podman-compose up ==="
    cd "$IKUKU_DIR"
    if command -v podman-compose &>/dev/null; then
      podman-compose up -d
      echo "Containers starting. Monitor: podman logs -f ikuku_frappe_1"
    elif command -v docker &>/dev/null; then
      docker compose up -d
      echo "Containers starting. Monitor: docker logs -f ikuku-frappe-1"
    else
      echo "Need podman-compose or docker compose. Install and retry."
      exit 1
    fi
    ;;
esac
