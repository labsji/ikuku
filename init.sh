#!/bin/bash
# init.sh - single bench, single site, apps from IKUKU_APPS env var
# IKUKU_APPS is a comma-separated list. Default: erpnext

APPS="${IKUKU_APPS:-erpnext}"  # SPEC-I02: ERPNext as default
SITE="ikuku.localhost"        # SPEC-I01: single site

# SPEC-I07: Idempotent — skip if bench already exists
if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
    cd frappe-bench
    bench start
    exit 0
fi

echo "Creating new bench..."
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
    if echo "$app" | grep -q "github.com"; then
        repo=$(echo "$app" | sed 's|.*github.com/||' | sed 's|\.git$||')
        app=$(basename "$repo")
    fi
    curl -sf "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4
}

# Install each selected app
IFS=',' read -ra APP_LIST <<< "$APPS"
for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    echo "Getting app: $app"
    if echo "$V16_APPS" | grep -qw "$app"; then
        bench get-app --branch "$FRAPPE_BRANCH" --resolve-deps "$app"
    else
        TAG=$(get_release_tag "$app")
        if [ -n "$TAG" ]; then
            echo "  Using release $TAG"
            bench get-app --branch "$TAG" --resolve-deps "$app" || bench get-app --resolve-deps "$app"
        else
            bench get-app --resolve-deps "$app" || bench get-app "$app"
        fi
    fi
done

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

# SPEC-I04: Install bind agent (if bundled)
if [ -f /workspace/shared/bind.tar.gz ]; then
    echo "Installing bind agent..."
    cd /home/frappe/frappe-bench/apps && rm -rf bind && mkdir bind && cd bind
    tar xzf /workspace/shared/bind.tar.gz
    cd /home/frappe/frappe-bench
    pip install -q -e apps/bind 2>/dev/null || ln -sf /home/frappe/frappe-bench/apps/bind/bind /home/frappe/frappe-bench/env/lib/python*/site-packages/bind
    grep -q bind sites/apps.txt || echo bind >> sites/apps.txt
    bench --site "$SITE" install-app bind 2>&1 | tail -1
    bench --site "$SITE" migrate 2>&1 | tail -1
fi

# Install Kiro CLI (if bundled)
if [ -f /workspace/shared/kiro-cli ]; then
    cp /workspace/shared/kiro-cli /usr/local/bin/kiro-cli
    chmod +x /usr/local/bin/kiro-cli
    echo "Kiro CLI installed: $(kiro-cli --version 2>/dev/null || echo 'ready')"
fi

# SPEC-I05: Configure LLM provider (ollama — open source, local)
bench --site "$SITE" set-config bind_llm '{"provider": "ollama", "model": "llama3.2"}' --parse

bench start
