#!/bin/bash
# create-dump.sh — Build frappe-bench from source, then export volume dumps
# Run this on a machine with Docker/Podman and plenty of disk (CloudShell overlay or EC2).
# Output: bench-dump.tar.zst + mariadb-dump.tar.zst → upload to S3
#
# Usage: bash create-dump.sh [--upload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPLOAD=false
S3_BUCKET="s3://ikuku-releases/dump"
REGION="ap-south-1"

if [[ "${1:-}" == "--upload" ]]; then
    UPLOAD=true
fi

# Use podman or docker
if command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
    CONTAINER_CMD="podman"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
    CONTAINER_CMD="docker"
else
    echo "ERROR: Need podman-compose or docker-compose"
    exit 1
fi

echo "=== Step 1: Build from source (this takes 10-15 min) ==="
cd "$SCRIPT_DIR"

# Clean any existing state
$COMPOSE down -v 2>/dev/null || true

# Start fresh build
$COMPOSE up -d

echo "Waiting for bench to finish building..."
echo "(Watching for 'ready' in status.txt or container exit)"

# Wait up to 20 min for init.sh to complete and write 'ready'
TIMEOUT=1200
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check if frappe container wrote status
    STATUS=$($CONTAINER_CMD exec ikuku_frappe_1 cat /workspace/status.txt 2>/dev/null || echo "")
    if [ "$STATUS" = "ready" ]; then
        echo "✓ Bench built successfully (${ELAPSED}s)"
        break
    fi
    # Check if container died
    if ! $CONTAINER_CMD ps | grep -q ikuku_frappe_1; then
        echo "ERROR: frappe container exited before ready"
        $CONTAINER_CMD logs ikuku_frappe_1 --tail 30
        exit 1
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    [ $((ELAPSED % 60)) -eq 0 ] && echo "  ... ${ELAPSED}s elapsed"
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: Timed out waiting for bench build"
    exit 1
fi

echo ""
echo "=== Step 2: Stop containers ==="
$COMPOSE stop

echo ""
echo "=== Step 3: Export frappe-bench volume ==="
# Volume name follows compose project naming: ikuku_frappe-bench
BENCH_VOL="ikuku_frappe-bench"
MARIA_VOL="ikuku_mariadb-data"

# Export bench volume
$CONTAINER_CMD run --rm \
    -v "${BENCH_VOL}:/data:ro" \
    -v /tmp:/out \
    alpine tar cf /out/bench-dump.tar -C /data .

echo "  bench-dump.tar: $(du -sh /tmp/bench-dump.tar | cut -f1)"

echo ""
echo "=== Step 4: Export mariadb-data volume ==="
$CONTAINER_CMD run --rm \
    -v "${MARIA_VOL}:/data:ro" \
    -v /tmp:/out \
    alpine tar cf /out/mariadb-dump.tar -C /data .

echo "  mariadb-dump.tar: $(du -sh /tmp/mariadb-dump.tar | cut -f1)"

echo ""
echo "=== Step 5: Compress with zstd ==="
if ! command -v zstd &>/dev/null; then
    echo "Installing zstd..."
    sudo yum install -y zstd 2>/dev/null || sudo apt-get install -y zstd 2>/dev/null || {
        echo "WARNING: zstd not available, using gzip"
        gzip -f /tmp/bench-dump.tar
        gzip -f /tmp/mariadb-dump.tar
        BENCH_DUMP="/tmp/bench-dump.tar.gz"
        MARIA_DUMP="/tmp/mariadb-dump.tar.gz"
    }
fi

if command -v zstd &>/dev/null; then
    zstd -f --rm -T0 /tmp/bench-dump.tar -o /tmp/bench-dump.tar.zst
    zstd -f --rm -T0 /tmp/mariadb-dump.tar -o /tmp/mariadb-dump.tar.zst
    BENCH_DUMP="/tmp/bench-dump.tar.zst"
    MARIA_DUMP="/tmp/mariadb-dump.tar.zst"
fi

echo "  $(basename $BENCH_DUMP): $(du -sh $BENCH_DUMP | cut -f1)"
echo "  $(basename $MARIA_DUMP): $(du -sh $MARIA_DUMP | cut -f1)"

echo ""
echo "=== Step 6: Verify dumps ==="
# Quick sanity check: bench dump should contain apps/frappe
if [[ "$BENCH_DUMP" == *.zst ]]; then
    zstd -dc "$BENCH_DUMP" | tar tf - | grep -q "apps/frappe" && echo "  ✓ bench dump contains apps/frappe" || { echo "  ✗ bench dump missing apps/frappe"; exit 1; }
    zstd -dc "$BENCH_DUMP" | tar tf - | grep -q "apps/erpnext" && echo "  ✓ bench dump contains apps/erpnext" || echo "  ⚠ bench dump missing erpnext (may be expected)"
else
    tar tf "$BENCH_DUMP" | grep -q "apps/frappe" && echo "  ✓ bench dump contains apps/frappe" || { echo "  ✗ bench dump missing apps/frappe"; exit 1; }
fi

if [ "$UPLOAD" = true ]; then
    echo ""
    echo "=== Step 7: Upload to S3 ==="
    aws s3 cp "$BENCH_DUMP" "$S3_BUCKET/$(basename $BENCH_DUMP)" --region "$REGION"
    aws s3 cp "$MARIA_DUMP" "$S3_BUCKET/$(basename $MARIA_DUMP)" --region "$REGION"
    echo "  ✓ Uploaded to $S3_BUCKET"
fi

echo ""
echo "=== Done ==="
echo "Dumps ready at:"
echo "  $BENCH_DUMP"
echo "  $MARIA_DUMP"
echo ""
echo "To upload manually: aws s3 cp <file> $S3_BUCKET/ --region $REGION"
