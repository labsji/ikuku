#!/bin/bash
# init.sh - single bench, multiple apps based on IKUKU_APPS env var
# IKUKU_APPS is a comma-separated list: "wiki,lms" or just "wiki"

APPS="${IKUKU_APPS:-wiki}"
DEMO_SITE="demo.localhost"
MVP_SITE="mvp.localhost"

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

# Install each selected app (once per bench, shared across sites)
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

# --- Site 1: Demo (pre-loaded with demo data) ---
echo "=== Creating demo site: $DEMO_SITE ==="
bench new-site "$DEMO_SITE" \
    --force \
    --mariadb-root-password 123 \
    --admin-password admin \
    --no-mariadb-socket

for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    bench --site "$DEMO_SITE" install-app "$app"
done

# Enable demo data if ERPNext is installed
if echo "$APPS" | grep -qw "erpnext"; then
    bench --site "$DEMO_SITE" execute erpnext.setup.demo.setup_demo_data 2>/dev/null || \
    echo "Demo data setup skipped (run setup wizard first)"
fi

bench --site "$DEMO_SITE" set-config developer_mode 1
bench --site "$DEMO_SITE" clear-cache

# --- Site 2: MVP (blank, for building prospect's config) ---
echo "=== Creating MVP site: $MVP_SITE ==="
bench new-site "$MVP_SITE" \
    --force \
    --mariadb-root-password 123 \
    --admin-password admin \
    --no-mariadb-socket

for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    bench --site "$MVP_SITE" install-app "$app"
done

bench --site "$MVP_SITE" set-config developer_mode 1
bench --site "$MVP_SITE" clear-cache

# Default site for direct IP access
bench use "$DEMO_SITE"

# Add second gunicorn for MVP site on port 8001
if grep -q "^web:" Procfile; then
    WEB_CMD=$(grep "^web:" Procfile | sed 's/^web: //')
    MVP_CMD=$(echo "$WEB_CMD" | sed 's/8000/8001/')
    echo "mvp: FRAPPE_SITE=$MVP_SITE $MVP_CMD" >> Procfile
fi

bench start

