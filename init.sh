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

# Setup training repo in local gitea (first boot only)
if [ ! -f /workspace/.training-init-done ]; then
    echo "Setting up training repo in gitea..."
    # Wait for gitea to be ready
    for i in $(seq 1 30); do
        curl -sf http://gitea:3000/api/v1/version > /dev/null 2>&1 && break
        sleep 2
    done

    # Create admin user + training repo via gitea API
    curl -sf http://gitea:3000/api/v1/admin/users -X POST \
        -H "Content-Type: application/json" \
        -d '{"username":"trainer","password":"trainer123","email":"trainer@local","must_change_password":false}' \
        > /dev/null 2>&1 || true

    curl -sf http://gitea:3000/api/v1/user/repos \
        -u "trainer:trainer123" -X POST \
        -H "Content-Type: application/json" \
        -d '{"name":"next-sale","auto_init":true,"default_branch":"main"}' \
        > /dev/null 2>&1 || true

    # Clone and populate with tutorials (from bundled or GitHub)
    cd /tmp
    if [ -f /workspace/shared/next-sale.bundle ]; then
        git clone /workspace/shared/next-sale.bundle next-sale
    elif [ -f /workspace/shared/next-sale.tar.gz ]; then
        mkdir next-sale && cd next-sale && tar xzf /workspace/shared/next-sale.tar.gz && git init && git add -A && git commit -m "init" && cd /tmp
    else
        git clone https://github.com/labsji/next-sale.git next-sale 2>/dev/null || mkdir -p next-sale
    fi

    if [ -d /tmp/next-sale/.git ]; then
        cd /tmp/next-sale
        git remote remove origin 2>/dev/null || true
        git remote add origin http://trainer:trainer123@gitea:3000/trainer/next-sale.git
        git push -u origin main 2>/dev/null || git push -u origin master 2>/dev/null || true
    fi

    rm -rf /tmp/next-sale
    touch /workspace/.training-init-done
    echo "Training repo ready at http://localhost:3000/trainer/next-sale"
fi

bench start
