#!/bin/bash
# build-layers-b.sh — build the Strategy-B layer set (see docs/LAYERS.md, schemaVersion 2).
#
# B ships: standard-Ubuntu base is NOT packaged (wsl --install pulls it). We package
#   1 app-images.tar.zst  (podman save of the 3 stock images)      role=app      cache=machine
#   2 kiro.tar.zst         (ONE copy of kiro-cli/kiro-cli-chat/bind) role=kiro     cache=machine
#   3 vol-frappe-bench.tar.zst (podman volume export)              role=vertical  cache=industry
#   4 vol-mariadb-data.tar.zst (podman volume export)              role=prospect  cache=none
#   5 prospect-<kit>.tar.zst   (ikuku.conf + niche-context.md + seed.repl) role=prospect cache=none
# and emits layers.json (schemaVersion 2, strategy B) with real sha256 + sizes.
#
# The app-images + kiro layers are IDENTICAL across prospects (content-addressed) —
# that is the reuse the installer's cache exploits.
#
# Usage:
#   build-layers-b.sh --kit al-souk-travel --out ./layers-b \
#       [--images "frappe/bench:latest mariadb:10.8 redis:alpine"] \
#       [--frappe-volume ikuku_frappe-bench] [--mariadb-volume ikuku_mariadb-data] \
#       [--kiro-dir /opt/ikuku/shared]        (dir containing kiro-cli, kiro-cli-chat, bind.tar.gz) \
#       [--prospect-dir ./prospect]           (dir with ikuku.conf, niche-context.md, seed.repl) \
#       [--vertical-id travel]                (names the vertical layer) \
#       [--skip-app]   (don't rebuild app-images/kiro — reuse existing ones in --out; for repeat prospects) \
#       [--podman "sudo podman"]
#
# For a REPEAT prospect on an existing base+app: pass --skip-app and only the
# vertical/prospect inputs; the app-images/kiro layers are not rebuilt (they're cached
# machine-side by the installer anyway).

set -euo pipefail

KIT=""
OUT="./layers-b"
IMAGES="docker.io/frappe/bench:latest docker.io/library/mariadb:10.8 docker.io/library/redis:alpine"
FRAPPE_VOL="ikuku_frappe-bench"
MARIADB_VOL="ikuku_mariadb-data"
KIRO_DIR=""
PROSPECT_DIR=""
VERTICAL_ID="generic"
SKIP_APP=0
REUSE_FROM=""
PODMAN="sudo podman"
DISTRO="Ubuntu"

while [ $# -gt 0 ]; do
  case "$1" in
    --kit) KIT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --images) IMAGES="$2"; shift 2 ;;
    --frappe-volume) FRAPPE_VOL="$2"; shift 2 ;;
    --mariadb-volume) MARIADB_VOL="$2"; shift 2 ;;
    --kiro-dir) KIRO_DIR="$2"; shift 2 ;;
    --prospect-dir) PROSPECT_DIR="$2"; shift 2 ;;
    --vertical-id) VERTICAL_ID="$2"; shift 2 ;;
    --skip-app) SKIP_APP=1; shift ;;
    --reuse-from) REUSE_FROM="$2"; shift 2 ;;
    --podman) PODMAN="$2"; shift 2 ;;
    --distro) DISTRO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$KIT" ] && { echo "ERROR: --kit required" >&2; exit 2; }
[ -z "$PROSPECT_DIR" ] && { echo "ERROR: --prospect-dir required" >&2; exit 2; }
mkdir -p "$OUT"

have_zstd() { command -v zstd >/dev/null 2>&1; }
comp() { # comp <in.tar> -> <in.tar.zst|.gz>, prints artifact path
  local f="$1"
  if have_zstd; then zstd -q -3 -T0 -f --rm "$f" -o "$f.zst"; echo "$f.zst"
  else gzip -f "$f"; echo "$f.gz"; fi
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
sz()  { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }

LAYER_JSON=()
add() { # add <id> <order> <role> <applyMode> <artifactPath|-> <cache> <desc> [volumeName]
  local id="$1" order="$2" role="$3" mode="$4" path="$5" cache="$6" desc="$7" vol="${8:-}"
  local fields="\"id\":\"$id\",\"order\":$order,\"role\":\"$role\",\"applyMode\":\"$mode\""
  if [ "$path" != "-" ]; then
    local art s z; art="$(basename "$path")"; s="$(sha "$path")"; z="$(sz "$path")"
    fields="$fields,\"artifact\":\"$art\",\"sha256\":\"$s\",\"size\":$z,\"cache\":\"$cache\""
    echo "  + $role/$id ($mode): $art  [$z bytes, ${s:0:12}...]"
  else
    echo "  + $role/$id ($mode): (no artifact)"
  fi
  [ -n "$vol" ] && fields="$fields,\"volumeName\":\"$vol\""
  fields="$fields,\"description\":\"$desc\""
  LAYER_JSON+=("    {$fields}")
}

echo "=== build-layers-b: kit '$KIT' -> $OUT ==="

# order 0: base (wsl-install, no artifact)
add "base-ubuntu" 0 "base" "wsl-install" "-" "-" "Standard Ubuntu via wsl --install -d $DISTRO + apt podman (not shipped)"
# patch wslDistro into the base entry
LAYER_JSON[0]="${LAYER_JSON[0]%\}*},\"wslDistro\":\"$DISTRO\"}"

if [ "$SKIP_APP" -eq 0 ]; then
  # order 1: app-images (podman save)
  echo "  podman save app images..."
  $PODMAN save -m -o "$OUT/app-images.tar" $IMAGES
  APP_ART="$(comp "$OUT/app-images.tar")"
  add "app-images" 1 "app" "podman-load" "$APP_ART" "machine" "podman save of $IMAGES; reused by every prospect"

  # order 2: kiro (overlay of a single copy into /opt/ikuku/shared)
  [ -z "$KIRO_DIR" ] && { echo "ERROR: --kiro-dir required unless --skip-app" >&2; exit 2; }
  echo "  packing kiro (one copy)..."
  kstage="$(mktemp -d)"; mkdir -p "$kstage/opt/ikuku/shared"
  for f in kiro-cli kiro-cli-chat bind.tar.gz; do
    [ -f "$KIRO_DIR/$f" ] && cp -a "$KIRO_DIR/$f" "$kstage/opt/ikuku/shared/"
  done
  tar cf "$OUT/kiro.tar" -C "$kstage" .
  rm -rf "$kstage"
  KIRO_ART="$(comp "$OUT/kiro.tar")"
  add "kiro" 2 "kiro" "overlay" "$KIRO_ART" "machine" "Single kiro-cli+kiro-cli-chat+bind -> /opt/ikuku/shared; reused by every prospect"
else
  # --skip-app: don't regenerate the tars, but still EMIT the app-images/kiro layer
  # entries (they must be in every kit's manifest so the installer can cache-HIT/ship).
  # Reuse existing artifacts from --reuse-from (default: --out).
  RF="${REUSE_FROM:-$OUT}"
  echo "  --skip-app: reusing app-images/kiro from $RF"
  [ -f "$RF/app-images.tar.zst" ] || { echo "ERROR: --skip-app but $RF/app-images.tar.zst missing" >&2; exit 2; }
  [ -f "$RF/kiro.tar.zst" ] || { echo "ERROR: --skip-app but $RF/kiro.tar.zst missing" >&2; exit 2; }
  [ "$RF" != "$OUT" ] && { cp -f "$RF/app-images.tar.zst" "$OUT/"; cp -f "$RF/kiro.tar.zst" "$OUT/"; }
  add "app-images" 1 "app" "podman-load" "$OUT/app-images.tar.zst" "machine" "podman save of $IMAGES; reused by every prospect"
  add "kiro" 2 "kiro" "overlay" "$OUT/kiro.tar.zst" "machine" "Single kiro-cli+kiro-cli-chat+bind -> /opt/ikuku/shared; reused by every prospect"
fi

# order 3: vertical (frappe-bench volume export)
echo "  exporting frappe-bench volume ($FRAPPE_VOL)..."
$PODMAN volume export "$FRAPPE_VOL" -o "$OUT/vol-frappe-bench.tar"
VFB_ART="$(comp "$OUT/vol-frappe-bench.tar")"
add "vertical-$VERTICAL_ID" 3 "vertical" "volume-import" "$VFB_ART" "industry" "frappe-bench volume for $VERTICAL_ID vertical" "$FRAPPE_VOL"

# order 4: prospect DB (mariadb volume export)
echo "  exporting mariadb volume ($MARIADB_VOL)..."
$PODMAN volume export "$MARIADB_VOL" -o "$OUT/vol-mariadb-data.tar"
VMD_ART="$(comp "$OUT/vol-mariadb-data.tar")"
add "prospect-$KIT-db" 4 "prospect" "volume-import" "$VMD_ART" "none" "Seeded ERPNext DB for $KIT" "$MARIADB_VOL"

# order 5: prospect config overlay (ikuku.conf + niche-context.md + seed.repl -> /opt/ikuku)
echo "  packing prospect config overlay..."
pstage="$(mktemp -d)"; mkdir -p "$pstage/opt/ikuku"
for f in ikuku.conf niche-context.md seed.repl; do
  [ -f "$PROSPECT_DIR/$f" ] && cp -a "$PROSPECT_DIR/$f" "$pstage/opt/ikuku/"
done
tar cf "$OUT/prospect-$KIT.tar" -C "$pstage" .
rm -rf "$pstage"
POP_ART="$(comp "$OUT/prospect-$KIT.tar")"
add "prospect-$KIT" 5 "prospect" "overlay" "$POP_ART" "none" "$KIT ikuku.conf + niche-context.md + seed.repl -> /opt/ikuku"

# emit manifest
manifest="$OUT/layers.json"
{
  echo "{"
  echo "  \"schemaVersion\": 2,"
  echo "  \"kit\": \"$KIT\","
  echo "  \"strategy\": \"B\","
  echo "  \"distro\": \"$DISTRO\","
  echo "  \"createdUtc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"layers\": ["
  for i in "${!LAYER_JSON[@]}"; do
    printf '%s' "${LAYER_JSON[$i]}"
    [ "$i" -lt $(( ${#LAYER_JSON[@]} - 1 )) ] && echo "," || echo ""
  done
  echo "  ]"
  echo "}"
} > "$manifest"

echo ""
echo "=== done. manifest: $manifest ==="
cat "$manifest"
