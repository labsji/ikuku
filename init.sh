#!/bin/bash
# init.sh - single bench, multiple apps based on IKUKU_APPS env var
# IKUKU_APPS is a comma-separated list: "wiki,lms" or just "wiki"

APPS="${IKUKU_APPS:-wiki}"
SITE="ikuku.localhost"

# Ensure writable directories on the persistent volume
mkdir -p /workspace/.ikuku 2>/dev/null || true

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
    cd frappe-bench
    # Ensure hosts point to compose service names (not build-time names)
    bench set-mariadb-host mariadb
    bench set-redis-cache-host redis://redis:6379
    bench set-redis-queue-host redis://redis:6379
    bench set-redis-socketio-host redis://redis:6379

    # If mariadb is fresh (no site DB), recreate the site
    SITE="ikuku.localhost"
    SITE_DB=$(python3 -c "import json;print(json.load(open('sites/$SITE/site_config.json')).get('db_name',''))" 2>/dev/null)
    # Wait for mariadb to be ready
    for i in $(seq 1 30); do
        env/bin/python -c "import MySQLdb; MySQLdb.connect(host='mariadb',user='root',passwd='123')" 2>/dev/null && break
        sleep 2
    done
    # Check if site DB exists
    DB_EXISTS=$(env/bin/python -c "
import MySQLdb
conn = MySQLdb.connect(host='mariadb',user='root',passwd='123')
cur = conn.cursor()
cur.execute('SHOW DATABASES')
dbs = [r[0] for r in cur.fetchall()]
print('yes' if '$SITE_DB' in dbs else 'no')
" 2>/dev/null || echo "no")
    if [ "$DB_EXISTS" = "no" ] && [ -n "$SITE_DB" ]; then
        echo "Site DB '$SITE_DB' missing (fresh mariadb). Recreating site..."
        bench new-site "$SITE" --force --mariadb-root-password 123 --admin-password admin --no-mariadb-socket
        for app in $(cat sites/apps.txt | grep -v frappe); do
            bench --site "$SITE" install-app "$app" 2>/dev/null || true
        done
        bench --site "$SITE" set-config developer_mode 1
        bench use "$SITE"
    fi

    # --- Kiro layer (idempotent — always refresh from /workspace/shared) ---
    if [ -f /workspace/shared/kiro-cli ]; then
        echo "Refreshing kiro-cli from /workspace/shared..."
        mkdir -p /home/frappe/.local/bin
        cp /workspace/shared/kiro-cli /home/frappe/.local/bin/kiro-cli
        cp /workspace/shared/kiro-cli-chat /home/frappe/.local/bin/kiro-cli-chat
        chmod +x /home/frappe/.local/bin/kiro-cli /home/frappe/.local/bin/kiro-cli-chat
        export PATH="/home/frappe/.local/bin:$PATH"
    fi
    if [ -f /workspace/shared/bind.tar.gz ] && [ ! -d apps/bind ]; then
        echo "Installing bind..."
        cd apps && rm -rf bind && mkdir bind && cd bind && tar xzf /workspace/shared/bind.tar.gz && cd ../..
        PYVER=$(ls env/lib/ | grep python | head -1)
        ln -sf /home/frappe/frappe-bench/apps/bind/bind "env/lib/$PYVER/site-packages/bind"
        [ -n "$(tail -c1 sites/apps.txt)" ] && echo >> sites/apps.txt
        grep -q '^bind$' sites/apps.txt || printf '%s\n' bind >> sites/apps.txt
        bench --site "$SITE" install-app bind || true
        bench --site "$SITE" set-config bind_llm '{"provider": "kiro", "home": "/home/frappe"}' --parse || true
        bench --site "$SITE" migrate
    fi

    # --- Kiro activation (idempotent — only if no token yet) ---
    if [ ! -f /workspace/.ikuku/token ] && [ -f /workspace/ikuku.conf ]; then
        # AUTH_ENDPOINT: ikuku.conf → env var → default
        AUTH_ENDPOINT=$(grep -E '^AUTH_ENDPOINT=' /workspace/ikuku.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')
        AUTH_ENDPOINT="${AUTH_ENDPOINT:-${IKUKU_AUTH_ENDPOINT:-https://auth.next.skith.in}}"
        mkdir -p /workspace/.ikuku
        echo "$AUTH_ENDPOINT" > /workspace/.ikuku/endpoint
        CODES=$(grep -E '^ACTIVATION_CODE(S)?=' /workspace/ikuku.conf | tail -1 | cut -d= -f2 | tr -d ' \r')
        if [ -n "$CODES" ]; then
            MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || hostname | sha256sum | cut -d' ' -f1)
            INSTALL_ID="${IKUKU_INSTALL_ID:-ikuku-$(hostname)}"
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
                    echo "✓ Kiro activated"
                    break
                fi
                echo "  Code failed, trying next..."
            done
            [ ! -f /workspace/.ikuku/token ] && echo "⚠ All activation codes failed."
        fi
    fi
    # Symlink so kiro-cli/bind can find it at ~/.ikuku
    mkdir -p /home/frappe/.ikuku
    [ -f /workspace/.ikuku/token ] && ln -sf /workspace/.ikuku/token /home/frappe/.ikuku/token
    [ -f /workspace/.ikuku/endpoint ] && ln -sf /workspace/.ikuku/endpoint /home/frappe/.ikuku/endpoint

    # --- Training content ---
    if [ ! -d /home/frappe/next-sale ] && [ -f /workspace/shared/next-sale.bundle ]; then
        echo "Cloning training content from bundle..."
        git clone /workspace/shared/next-sale.bundle /home/frappe/next-sale
        cd /home/frappe/next-sale && git checkout tutor-main 2>/dev/null || true
        cd /home/frappe/frappe-bench
    fi

    bench start
    exit 0
else
    echo "Creating new bench..."
fi

export PATH="${NVM_DIR}/versions/node/v${NODE_VERSION_DEVELOP}/bin/:${PATH}"

FRAPPE_BRANCH="${IKUKU_BRANCH:-version-16}"

bench init --skip-redis-config-generation --frappe-branch "$FRAPPE_BRANCH" frappe-bench
cd frappe-bench

bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

# Map of apps that have a matching frappe version branch
V16_APPS="erpnext hrms payments"

# Get latest release tag for an app from GitHub
get_release_tag() {
    local app="$1"
    local repo="frappe/$app"
    # For URLs, extract repo from URL
    if echo "$app" | grep -q "github.com"; then
        repo=$(echo "$app" | sed 's|.*github.com/||' | sed 's|\.git$||')
        app=$(basename "$repo")
    fi
    curl -sf "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4
}

# Install each selected app (with retry)
IFS=',' read -ra APP_LIST <<< "$APPS"
for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    echo "Getting app: $app"
    GOT_APP=false
    for attempt in 1 2 3; do
        if echo "$V16_APPS" | grep -qw "$app"; then
            bench get-app --branch "$FRAPPE_BRANCH" --resolve-deps "$app" && GOT_APP=true && break
        else
            TAG=$(get_release_tag "$app")
            if [ -n "$TAG" ]; then
                echo "  Using release $TAG (attempt $attempt)"
                (bench get-app --branch "$TAG" --resolve-deps "$app" || bench get-app --resolve-deps "$app") && GOT_APP=true && break
            else
                (bench get-app --resolve-deps "$app" || bench get-app "$app") && GOT_APP=true && break
            fi
        fi
        echo "  Attempt $attempt failed, retrying in 10s..."
        sleep 10
    done
    if [ "$GOT_APP" = "false" ]; then
        echo "ERROR: Failed to get app '$app' after 3 attempts"
    fi
done

# Verify critical apps are present before creating site
if [ ! -d "apps/erpnext" ] && echo "$APPS" | grep -q "erpnext"; then
    echo "FATAL: erpnext app not found. Cannot create site."
    echo "error" > /workspace/status.txt 2>/dev/null
    echo "error" > /mnt/c/ikuku/status.txt 2>/dev/null
    exit 1
fi

bench new-site "$SITE" \
--force \
--mariadb-root-password 123 \
--admin-password admin \
--no-mariadb-socket

for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    echo "Installing app: $app"
    bench --site "$SITE" install-app "$app"
done

bench --site "$SITE" set-config developer_mode 1
bench --site "$SITE" clear-cache
bench use "$SITE"
bench set-config -g serve_default_site True --parse

# --- Kiro layer: install kiro-cli + bind with kiro provider ---
# All binaries bundled in /workspace/shared/ by the NSIS installer — no runtime downloads.
echo "Installing kiro-cli..."
if [ ! -f /home/frappe/.local/bin/kiro-cli ]; then
    mkdir -p /home/frappe/.local/bin
    cp /workspace/shared/kiro-cli /home/frappe/.local/bin/kiro-cli
    cp /workspace/shared/kiro-cli-chat /home/frappe/.local/bin/kiro-cli-chat
    chmod +x /home/frappe/.local/bin/kiro-cli /home/frappe/.local/bin/kiro-cli-chat
fi
export PATH="/home/frappe/.local/bin:$PATH"

echo "Installing bind (kiro-layer)..."
cd /home/frappe/frappe-bench/apps && rm -rf bind && mkdir bind && cd bind && tar xzf /workspace/shared/bind.tar.gz
cd /home/frappe/frappe-bench
PYVER=$(ls env/lib/ | grep python | head -1)
ln -sf /home/frappe/frappe-bench/apps/bind/bind "env/lib/$PYVER/site-packages/bind"
# Ensure apps.txt ends with newline before appending
[ -n "$(tail -c1 sites/apps.txt)" ] && echo >> sites/apps.txt
grep -q '^bind$' sites/apps.txt || printf '%s\n' bind >> sites/apps.txt
bench --site "$SITE" install-app bind || true
bench --site "$SITE" set-config bind_llm '{"provider": "kiro", "home": "/home/frappe"}' --parse || true
bench --site "$SITE" migrate

# --- Load seed.repl if present (pre-configured niche from evalKit) ---
if [ -f /workspace/seed.repl ]; then
    echo "Loading seed.repl (pre-configured niche)..."
    cd /home/frappe/frappe-bench
    env/bin/python -c "
import frappe, sys
frappe.init(site='$SITE')
frappe.connect()
frappe.set_user('Administrator')
sys.path.insert(0, '/home/frappe/frappe-bench/apps/bind')
from bind.parser import parse
from bind.executor import execute

with open('/workspace/seed.repl') as f:
    content = f.read()

blocks = [b.strip() for b in content.split('\n\n') if b.strip() and b.strip().startswith('create')]
success = 0
for block in blocks:
    try:
        parsed = parse(block)
        if parsed:
            execute(parsed)
            success += 1
    except Exception as e:
        pass  # skip duplicates/errors silently

frappe.db.commit()
print(f'  Seed loaded: {success}/{len(blocks)} records created')
" || echo "  ⚠ Seed loading failed (non-fatal)"
fi

# Copy niche-context.md into Kiro instructions if present
if [ -f /workspace/niche-context.md ]; then
    echo "Loading niche context for Kiro..."
    mkdir -p /home/frappe/.kiro
    if [ -f /home/frappe/.kiro/instructions.md ]; then
        echo "" >> /home/frappe/.kiro/instructions.md
        echo "## Prospect Context" >> /home/frappe/.kiro/instructions.md
        cat /workspace/niche-context.md >> /home/frappe/.kiro/instructions.md
    else
        cp /workspace/niche-context.md /home/frappe/.kiro/instructions.md
    fi
fi

# --- Kiro activation (headless via auth proxy) ---
# OTP baked by reseller via evalKit.sh into ikuku.conf alongside the exe
# AUTH_ENDPOINT: ikuku.conf → env var → default
AUTH_ENDPOINT=$(grep -E '^AUTH_ENDPOINT=' /workspace/ikuku.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' \r')
AUTH_ENDPOINT="${AUTH_ENDPOINT:-${IKUKU_AUTH_ENDPOINT:-https://auth.next.skith.in}}"
mkdir -p /workspace/.ikuku /home/frappe/.ikuku
echo "$AUTH_ENDPOINT" > /workspace/.ikuku/endpoint

if [ ! -f /workspace/.ikuku/token ]; then
    # Read codes from ikuku.conf (comma-separated) or env
    CODES="${IKUKU_OTP:-}"
    if [ -z "$CODES" ] && [ -f /workspace/ikuku.conf ]; then
        CODES=$(grep -E '^ACTIVATION_CODE(S)?=' /workspace/ikuku.conf | tail -1 | cut -d= -f2 | tr -d ' \r')
    fi
    if [ -n "$CODES" ]; then
        MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || hostname | sha256sum | cut -d' ' -f1)
        INSTALL_ID="${IKUKU_INSTALL_ID:-ikuku-$(hostname)}"
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
                echo "✓ Kiro activated"
                break
            fi
            echo "  Code failed, trying next..."
        done
        [ ! -f /workspace/.ikuku/token ] && echo "⚠ All activation codes failed. Run manually: kiro-cli login --use-device-flow"
    else
        echo "⚠ No activation codes found. Add ACTIVATION_CODES to ikuku.conf or run: kiro-cli login --use-device-flow"
    fi
fi
# Symlink so kiro-cli/bind can find it at ~/.ikuku
ln -sf /workspace/.ikuku/token /home/frappe/.ikuku/token 2>/dev/null
ln -sf /workspace/.ikuku/endpoint /home/frappe/.ikuku/endpoint 2>/dev/null

# --- Training content (next-sale from bundled git bundle) ---
if [ ! -d /home/frappe/next-sale ] && [ -f /workspace/shared/next-sale.bundle ]; then
    echo "Cloning training content from bundle..."
    git clone /workspace/shared/next-sale.bundle /home/frappe/next-sale
    cd /home/frappe/next-sale && git checkout tutor-main 2>/dev/null || true
fi

cd /home/frappe/frappe-bench

# Signal ready (tray reads this)
echo "ready" > /workspace/status.txt 2>/dev/null
echo "ready" > /mnt/c/ikuku/status.txt 2>/dev/null
echo "✓ ikuku ready — starting bench..."

bench start

