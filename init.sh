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

FRAPPE_BRANCH="${IKUKU_BRANCH:-version-15}"

bench init --skip-redis-config-generation --frappe-branch "$FRAPPE_BRANCH" frappe-bench
cd frappe-bench

bench set-mariadb-host mariadb
bench set-redis-cache-host redis://redis:6379
bench set-redis-queue-host redis://redis:6379
bench set-redis-socketio-host redis://redis:6379

sed -i '/redis/d' ./Procfile
sed -i '/watch/d' ./Procfile

# Install each selected app — resolve-deps picks compatible versions automatically
IFS=',' read -ra APP_LIST <<< "$APPS"
for app in "${APP_LIST[@]}"; do
    app=$(echo "$app" | xargs)
    echo "Getting app: $app"
    bench get-app --resolve-deps "$app" || bench get-app "$app"
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
bench --site "$SITE" set-config setup_complete 1
bench --site "$SITE" clear-cache
bench use "$SITE"

bench start

