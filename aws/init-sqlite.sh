#!/bin/bash
# init-sqlite.sh - Lightweight Frappe V16 setup with SQLite backend
# Designed for ARM64 (t4g.nano) on Amazon Linux 2023
# Usage: bash aws/init-sqlite.sh [domain-name]
set -e

DOMAIN="${1:-}"
SITE="${DOMAIN:-frappe.localhost}"
BENCH_DIR="/home/frappe/frappe-bench"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_PREFIX="sites-backup"
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")

# --- S3 Restore: Check for existing backup before fresh init ---
restore_from_s3() {
    if [ -z "$BACKUP_BUCKET" ]; then
        echo "No BACKUP_BUCKET set, skipping S3 restore"
        return 1
    fi

    echo "Checking S3 for existing site backup..."
    if aws s3 ls "s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/latest.tar.gz" --region "$REGION" 2>/dev/null; then
        echo "Found existing backup, restoring from S3..."
        mkdir -p "$BENCH_DIR"
        aws s3 cp "s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/latest.tar.gz" /tmp/site-backup.tar.gz --region "$REGION"
        tar xzf /tmp/site-backup.tar.gz -C "$BENCH_DIR"
        rm -f /tmp/site-backup.tar.gz
        chown -R frappe:frappe "$BENCH_DIR"
        echo "Site restored from S3 backup"
        return 0
    else
        echo "No backup found in S3, proceeding with fresh install"
        return 1
    fi
}

# --- S3 Backup: Create hourly cron job ---
setup_backup_cron() {
    if [ -z "$BACKUP_BUCKET" ]; then
        echo "No BACKUP_BUCKET set, skipping backup cron setup"
        return
    fi

    echo "Setting up hourly S3 backup cron..."
    cat > /etc/cron.d/frappe-s3-backup << CRONEOF
# Backup Frappe sites directory to S3 every hour
0 * * * * root /usr/local/bin/frappe-s3-backup.sh >> /var/log/frappe-backup.log 2>&1
CRONEOF

    cat > /usr/local/bin/frappe-s3-backup.sh << 'SCRIPTEOF'
#!/bin/bash
set -e
BENCH_DIR="/home/frappe/frappe-bench"
SCRIPTEOF

    cat >> /usr/local/bin/frappe-s3-backup.sh << SCRIPTEOF
BACKUP_BUCKET="${BACKUP_BUCKET}"
BACKUP_PREFIX="${BACKUP_PREFIX}"
REGION="${REGION}"
SCRIPTEOF

    cat >> /usr/local/bin/frappe-s3-backup.sh << 'SCRIPTEOF'

if [ ! -d "$BENCH_DIR/sites" ]; then
    echo "No sites directory found, skipping backup"
    exit 0
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="/tmp/frappe-backup-${TIMESTAMP}.tar.gz"

# Create tarball of sites directory (includes SQLite DB and site config)
tar czf "$BACKUP_FILE" -C "$BENCH_DIR" sites/ apps/ Procfile

# Upload timestamped backup
aws s3 cp "$BACKUP_FILE" "s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/backup-${TIMESTAMP}.tar.gz" --region "$REGION"

# Also upload as latest (for restore on new instance boot)
aws s3 cp "$BACKUP_FILE" "s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/latest.tar.gz" --region "$REGION"

rm -f "$BACKUP_FILE"
echo "Backup complete: backup-${TIMESTAMP}.tar.gz"
SCRIPTEOF

    chmod +x /usr/local/bin/frappe-s3-backup.sh
    echo "Backup cron installed"
}

# --- Idempotent check: skip if bench already exists ---
if [ -d "$BENCH_DIR/apps/frappe" ]; then
    echo "Bench already exists at $BENCH_DIR, skipping init"
    setup_backup_cron
    exit 0
fi

echo "=== Frappe V16 SQLite Init (ARM64) ==="

# --- Try restoring from S3 first ---
if restore_from_s3; then
    echo "Restored from S3 backup, setting up services..."
    # Still need system deps and services even after restore
    dnf install -y \
        python3.11 python3.11-devel python3.11-pip \
        nodejs npm \
        redis6 \
        gcc gcc-c++ make \
        git curl wget \
        cairo-devel pango-devel \
        libffi-devel openssl-devel \
        wkhtmltopdf || true
    alternatives --set python3 /usr/bin/python3.11 2>/dev/null || true
    npm install -g yarn 2>/dev/null || true
    systemctl enable redis6
    systemctl start redis6
    id frappe &>/dev/null || useradd -m -s /bin/bash frappe
    chown -R frappe:frappe "$BENCH_DIR"
    su - frappe -c "pip3.11 install --user frappe-bench"

    # Install Caddy
    dnf install -y 'dnf-command(copr)' 2>/dev/null || true
    dnf copr enable -y @caddy/caddy 2>/dev/null || true
    dnf install -y caddy 2>/dev/null || {
        curl -fsSL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_2.7.6_linux_arm64.tar.gz" \
            -o /tmp/caddy.tar.gz
        tar xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy
        chmod +x /usr/local/bin/caddy
        rm -f /tmp/caddy.tar.gz
    }

    # Deploy Caddyfile
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/Caddyfile" ]; then
        cp "$SCRIPT_DIR/Caddyfile" /etc/caddy/Caddyfile
    fi
    if [ -n "$DOMAIN" ]; then
        sed -i "s/{{SITE_ADDRESS}}/$DOMAIN/" /etc/caddy/Caddyfile
    else
        sed -i "s/{{SITE_ADDRESS}}/:80/" /etc/caddy/Caddyfile
    fi
    systemctl enable caddy
    systemctl start caddy

    # Deploy systemd service
    if [ -f "$SCRIPT_DIR/frappe-bench.service" ]; then
        cp "$SCRIPT_DIR/frappe-bench.service" /etc/systemd/system/frappe-bench.service
    fi
    systemctl daemon-reload
    systemctl enable frappe-bench
    systemctl start frappe-bench

    # Set up backup cron
    setup_backup_cron

    echo "=== Restore complete - site is running ==="
    exit 0
fi

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

# Remove redis entries from Procfile (system redis used instead)
# Use ^redis_ to match only redis process entries, not other lines containing "redis"
sed -i '/^redis_/d' "$BENCH_DIR/Procfile"

# --- Create site with SQLite ---
ADMIN_PWD="${ADMIN_PASSWORD:-admin}"
echo "Creating site '$SITE' with SQLite backend..."
su - frappe -c "
    export PATH=\$HOME/.local/bin:\$PATH
    cd $BENCH_DIR
    bench new-site $SITE --db-type sqlite --admin-password '$ADMIN_PWD'
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

# Set domain in Caddyfile if provided, otherwise default to :80
if [ -n "$DOMAIN" ]; then
    sed -i "s/{{SITE_ADDRESS}}/$DOMAIN/" /etc/caddy/Caddyfile
else
    sed -i "s/{{SITE_ADDRESS}}/:80/" /etc/caddy/Caddyfile
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
echo "Admin password: (set via ADMIN_PASSWORD environment variable)"
if [ -n "$DOMAIN" ]; then
    echo "URL: https://$DOMAIN"
else
    echo "URL: http://<instance-ip>"
fi

# --- Set up S3 backup cron ---
setup_backup_cron

# --- Run initial backup immediately ---
if [ -n "$BACKUP_BUCKET" ] && [ -x /usr/local/bin/frappe-s3-backup.sh ]; then
    echo "Running initial S3 backup..."
    /usr/local/bin/frappe-s3-backup.sh || echo "Initial backup failed (non-fatal)"
fi
