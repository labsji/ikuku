#!/bin/bash
# init.sh - single bench, multiple apps based on IKUKU_APPS env var
# IKUKU_APPS is a comma-separated list: "wiki,lms" or just "wiki"

APPS="${IKUKU_APPS:-wiki}"
SITE="ikuku.localhost"

if [ -d "/home/frappe/frappe-bench/apps/frappe" ]; then
    echo "Bench already exists, skipping init"
    cd frappe-bench
    bench start
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

# --- Kiro layer: install kiro-cli + bind with kiro provider ---
echo "Installing kiro-cli..."
if [ ! -f /usr/local/bin/kiro-cli ]; then
    curl -sfL "https://ikuku-releases.s3.ap-south-1.amazonaws.com/kiro/kiro-cli" -o /usr/local/bin/kiro-cli
    curl -sfL "https://ikuku-releases.s3.ap-south-1.amazonaws.com/kiro/kiro-cli-chat" -o /usr/local/bin/kiro-cli-chat
    chmod +x /usr/local/bin/kiro-cli /usr/local/bin/kiro-cli-chat
fi

echo "Installing bind (kiro-layer)..."
curl -sfL "https://ikuku-releases.s3.ap-south-1.amazonaws.com/bind/bind.tar.gz" -o /tmp/bind.tar.gz
cd /home/frappe/frappe-bench/apps && rm -rf bind && mkdir bind && cd bind && tar xzf /tmp/bind.tar.gz
cd /home/frappe/frappe-bench
PYVER=$(ls env/lib/ | grep python | head -1)
ln -sf /home/frappe/frappe-bench/apps/bind/bind "env/lib/$PYVER/site-packages/bind"
grep -q '^bind$' sites/apps.txt || printf '%s\n' bind >> sites/apps.txt
bench --site "$SITE" install-app bind || true
bench --site "$SITE" set-config bind_llm '{"provider": "kiro", "home": "/home/frappe"}' --parse || true
bench --site "$SITE" migrate

bench start

