#!/bin/bash
# boot.sh - run by /etc/wsl.conf [boot] command on every WSL distro start.
# Brings the ERPNext container stack up via podman-compose (which restores the
# pod network + DNS aliases so redis/mariadb resolve). Runs in the background so
# WSL boot isn't blocked. Idempotent.
{
    cd /opt/ikuku || exit 0
    # If containers already Up, do nothing. Otherwise (re)create via compose so the
    # network aliases exist. `podman start` alone loses compose DNS after a cold boot.
    if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q ikuku_frappe_1; then
        podman-compose up -d 2>/dev/null || {
            # Fallback: create then start
            podman start ikuku_mariadb_1 ikuku_redis_1 ikuku_frappe_1 2>/dev/null
        }
    fi
} >/var/log/ikuku-boot.log 2>&1 &
