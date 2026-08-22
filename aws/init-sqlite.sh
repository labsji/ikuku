#!/bin/bash
# init-sqlite.sh - Lightweight Frappe V16 setup with SQLite backend
# Designed for ARM64 (t4g.nano) on Amazon Linux 2023
# Usage: bash aws/init-sqlite.sh [domain-name]
set -e

DOMAIN="${1:-}"
SITE="${DOMAIN:-frappe.localhost}"
BENCH_DIR="/home/frappe/frappe-bench"

# --- Idempotent check: skip if bench already exists ---
if [ -d "$BENCH_DIR/apps/frappe" ]; then
    echo "Bench already exists at $BENCH_DIR, skipping init"
    exit 0
fi

echo "=== Frappe V16 SQLite Init (ARM64) ==="

# --- Install system dependencies ---
echo "Installing system dependencies..."
dnf install -y \
    python3.11 python3.11-devel python3.11-pip \
    nodejs npm \
    redis6 \
    gcc gcc-c++ make \
    git curl wget \
    cairo-devel pango-devel \
    libffi-devel openssl-devel \
    wkhtmltopdf || true

# Ensure python3 points to 3.11
alternatives --set python3 /usr/bin/python3.11 2>/dev/null || true

# --- Install Yarn ---
echo "Installing Yarn..."
npm install -g yarn 2>/dev/null || true

# --- Start and enable Redis ---
echo "Starting Redis..."
systemctl enable redis6
systemctl start redis6

# --- Create frappe user ---
echo "Setting up frappe user..."
id frappe &>/dev/null || useradd -m -s /bin/bash frappe

# --- Install bench as frappe user ---
echo "Installing bench CLI..."
su - frappe -c "pip3.11 install --user frappe-bench"

# --- Initialize bench ---
echo "Initializing frappe-bench with Frappe V16..."
su - frappe -c "
    export PATH=\$HOME/.local/bin:\$PATH
    cd \$HOME
    bench init --skip-redis-config-generation --frappe-branch version-16 frappe-bench
"

# --- Configure Redis hosts ---
echo "Configuring Redis..."
su - frappe -c "
    export PATH=\$HOME/.local/bin:\$PATH
    cd $BENCH_DIR
    bench set-redis-cache-host redis://localhost:6379
    bench set-redis-queue-host redis://localhost:6379
    bench set-redis-socketio-host redis://localhost:6379
"

# Remove redis from Procfile (system redis used instead)
sed -i '/redis/d' "$BENCH_DIR/Procfile"

# --- Create site with SQLite ---
echo "Creating site '$SITE' with SQLite backend..."
su - frappe -c "
    export PATH=\$HOME/.local/bin:\$PATH
    cd $BENCH_DIR
    bench new-site $SITE --db-type sqlite --admin-password admin
    bench use $SITE
"

# --- Install apps ---
echo "Installing wiki app..."
su - frappe -c "
    export PATH=\$HOME/.local/bin:\$PATH
    cd $BENCH_DIR
    bench get-app --branch version-16 --resolve-deps wiki https://github.com/frappe/wiki.git
    bench --site $SITE install-app wiki
"

echo "Installing bind app..."
su - frappe -c "
    export PATH=\$HOME/.local/bin:\$PATH
    cd $BENCH_DIR
    bench get-app --resolve-deps bind https://github.com/labsji/bind.git || echo 'bind app not available, skipping'
    bench --site $SITE install-app bind 2>/dev/null || echo 'bind install skipped'
"

# --- Install Kiro CLI ---
echo "Installing Kiro CLI..."
ARCH="aarch64"
KIRO_URL="https://github.com/labsji/kiro-cli/releases/latest/download/kiro-cli-linux-${ARCH}"
curl -fsSL "$KIRO_URL" -o /usr/local/bin/kiro-cli 2>/dev/null || echo "Kiro CLI download not available"
chmod +x /usr/local/bin/kiro-cli 2>/dev/null || true
echo "Kiro CLI: $(kiro-cli --version 2>/dev/null || echo 'not installed')"

# --- Install Caddy reverse proxy ---
echo "Installing Caddy..."
dnf install -y 'dnf-command(copr)' 2>/dev/null || true
dnf copr enable -y @caddy/caddy 2>/dev/null || true
dnf install -y caddy 2>/dev/null || {
    # Fallback: install from GitHub releases
    curl -fsSL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_2.7.6_linux_arm64.tar.gz" \
        -o /tmp/caddy.tar.gz
    tar xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy
    chmod +x /usr/local/bin/caddy
    rm -f /tmp/caddy.tar.gz
}

# --- Deploy Caddyfile ---
echo "Configuring Caddy reverse proxy..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/Caddyfile" ]; then
    cp "$SCRIPT_DIR/Caddyfile" /etc/caddy/Caddyfile
fi

# Set domain in Caddyfile if provided
if [ -n "$DOMAIN" ]; then
    sed -i "s/:80/$DOMAIN/" /etc/caddy/Caddyfile
fi

systemctl enable caddy
systemctl start caddy

# --- Install and enable frappe-bench systemd service ---
echo "Setting up frappe-bench systemd service..."
if [ -f "$SCRIPT_DIR/frappe-bench.service" ]; then
    cp "$SCRIPT_DIR/frappe-bench.service" /etc/systemd/system/frappe-bench.service
fi
systemctl daemon-reload
systemctl enable frappe-bench
systemctl start frappe-bench

echo "=== Frappe V16 SQLite setup complete ==="
echo "Site: $SITE"
echo "Admin password: admin"
if [ -n "$DOMAIN" ]; then
    echo "URL: https://$DOMAIN"
else
    echo "URL: http://<instance-ip>"
fi
