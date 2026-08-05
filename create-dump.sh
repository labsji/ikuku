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

# For the build phase, use a temporary compose override that removes the frappe-bench volume
# (the volume mount prevents bench init from working on an empty directory)
cat > /tmp/docker-compose.dump-build.yml << 'YAML'
version: "3.7"
name: ikuku
services:
  mariadb:
    image: mariadb:10.8
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --skip-innodb-read-only-compressed
    environment:
      MYSQL_ROOT_PASSWORD: 123
    volumes:
      - mariadb-data:/var/lib/mysql
  redis:
    image: redis:alpine
  frappe:
    image: frappe/bench:latest
    command: bash /workspace/init.sh
    environment:
      - SHELL=/bin/bash
      - IKUKU_APPS=${IKUKU_APPS:-erpnext}
    working_dir: /home/frappe
    volumes:
      - .:/workspace
    ports:
      - 8000:8000
      - 9000:9000
      - 2718:2718
      - 7681:7681
volumes:
  mariadb-data:
YAML

# Copy init.sh and docker-compose to use the build version
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/docker-compose.yml.bak"
cp /tmp/docker-compose.dump-build.yml "$SCRIPT_DIR/docker-compose.yml"

# Start fresh build (no frappe-bench volume — bench builds in container filesystem)
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

# Restore original docker-compose.yml (with frappe-bench volume for production use)
if [ -f "$SCRIPT_DIR/docker-compose.yml.bak" ]; then
    mv "$SCRIPT_DIR/docker-compose.yml.bak" "$SCRIPT_DIR/docker-compose.yml"
fi

MARIA_VOL="ikuku_mariadb-data"

echo ""
echo "=== Step 3: Export frappe-bench from container ==="
# Since we built without the frappe-bench named volume, export directly from container
$CONTAINER_CMD cp ikuku_frappe_1:/home/frappe/frappe-bench /tmp/frappe-bench-export
tar cf /tmp/bench-dump.tar -C /tmp/frappe-bench-export .
rm -rf /tmp/frappe-bench-export

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
    zstd -dc "$BENCH_DUMP" | tar tf - | grep -q "sites/" && echo "  ✓ bench dump contains sites/" || echo "  ⚠ bench dump missing sites/"
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
