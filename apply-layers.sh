#!/bin/bash
# apply-layers.sh — in-guest composer for ikuku layered delivery (Strategy A + B).
#
# Runs INSIDE the base distro at first boot and applies the higher layers in manifest
# order, then hands off to the idempotent composer (init.sh) + niche Kiro (activate.sh).
#
# Supported applyModes (see docs/LAYERS.md, docs/layers.schema.json):
#   wsl-install   (B base)  — base already provided by `wsl --install`; nothing to do here
#   import        (A base)  — base already `wsl --import`ed by install.ps1; skip
#   podman-load   (B app)   — `podman load` a `podman save` image tar into the default store
#   volume-import (B vol)   — `podman volume create` + `podman volume import` a volume tar
#   overlay       (A/B)     — extract a tar over the distro root (files land at /opt/ikuku, etc.)
#
# Contract with install.ps1:
#   install.ps1 drops the manifest + all artifacts into /opt/ikuku/layers/ then runs:
#     wsl -d <distro> -u root -- bash /opt/ikuku/apply-layers.sh
#
# Idempotent: each applied layer records a marker /opt/ikuku/.layers-applied/<sha256>
#   (or /<id> for artifact-less layers); re-runs skip applied layers unless --force.
# Offline-safe: no network needed to apply layers.

set -uo pipefail

LAYERS_DIR="${IKUKU_LAYERS_DIR:-/opt/ikuku/layers}"
MANIFEST="$LAYERS_DIR/layers.json"
APPLIED_DIR="/opt/ikuku/.layers-applied"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { echo "[apply-layers] $*"; }
die() { echo "[apply-layers] ERROR: $*" >&2; exit 1; }

[ -f "$MANIFEST" ] || die "manifest not found at $MANIFEST"
command -v python3 >/dev/null 2>&1 || die "python3 required to parse manifest"
mkdir -p "$APPLIED_DIR"

PODMAN="${IKUKU_PODMAN:-podman}"
have_podman() { command -v "$PODMAN" >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; }

# --- Parse manifest into ordered lines separated by US (0x1f), which never appears in
# our fields. (TAB fails: bash `read` with IFS=tab collapses consecutive tabs since tab
# is whitespace-class, shifting fields when artifact/sha/vol are empty.) ---
US=$'\x1f'
mapfile -t LAYER_LINES < <(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
US = "\x1f"
for l in sorted(m.get("layers", []), key=lambda l: l.get("order", 0)):
    print(US.join([
        str(l.get("order","")), l.get("role",""), l.get("artifact",""),
        l.get("sha256",""), l.get("applyMode",""), l.get("volumeName",""), l.get("id",""),
    ]))
PY
)
[ "${#LAYER_LINES[@]}" -gt 0 ] || die "no layers in manifest"

# Ensure zstd is available (layers are .tar.zst). Self-heal via apt if missing +online.
ensure_zstd() {
    command -v zstd >/dev/null 2>&1 && return 0
    log "zstd missing — attempting apt-get install zstd"
    apt-get install -y -qq zstd >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq zstd >/dev/null 2>&1; }
    command -v zstd >/dev/null 2>&1
}

# decompress a tar[.zst|.gz] to stdout
cat_tar() {
    local path="$1"
    case "$path" in
        *.zst) ensure_zstd || die "zstd needed for $path but could not be installed"; zstd -dc "$path" ;;
        *.gz|*.tgz) gunzip -c "$path" ;;
        *) cat "$path" ;;
    esac
}

verify_digest() { # verify_digest <artifactPath> <sha>
    local path="$1" sha="$2"
    [ -z "$sha" ] && return 0
    echo "$sha" | grep -qE '^0{64}$' && return 0   # placeholder, skip
    local actual; actual="$(sha256sum "$path" | cut -d' ' -f1)"
    [ "$actual" = "$sha" ] || die "digest mismatch for $(basename "$path") (manifest $sha, actual $actual)"
}

log "manifest: $MANIFEST (${#LAYER_LINES[@]} layers)"
for line in "${LAYER_LINES[@]}"; do
    IFS="$US" read -r order role artifact sha mode vol id <<< "$line"

    # marker key: sha if present, else the layer id (for artifact-less layers)
    mkey="${sha:-$id}"; [ -z "$mkey" ] && mkey="$role-$order"
    marker="$APPLIED_DIR/$mkey"
    if [ "$FORCE" -eq 0 ] && [ -f "$marker" ]; then
        log "layer '$id' ($role/$mode, order $order) already applied — skipping"
        continue
    fi

    case "$mode" in
        wsl-install|import)
            log "layer '$id' ($role/$mode) is the base — provided by installer, skipping"
            touch "$marker"; continue ;;

        podman-load)
            path="$LAYERS_DIR/$artifact"; [ -f "$path" ] || die "podman-load artifact missing: $path"
            verify_digest "$path" "$sha"
            have_podman || die "podman not installed but layer '$id' needs podman-load"
            log "podman load '$id' ($artifact)"
            # capture pipeline status so a failed load aborts (PIPESTATUS, not the tail's rc)
            cat_tar "$path" | $PODMAN load > /tmp/ikuku-load.out 2>&1
            if [ "${PIPESTATUS[0]}" -ne 0 ] || [ "${PIPESTATUS[1]}" -ne 0 ]; then
                sed 's/^/  /' /tmp/ikuku-load.out >&2; die "podman load failed for $id"
            fi
            sed 's/^/  /' /tmp/ikuku-load.out | tail -6
            touch "$marker" ;;

        volume-import)
            path="$LAYERS_DIR/$artifact"; [ -f "$path" ] || die "volume-import artifact missing: $path"
            [ -n "$vol" ] || die "layer '$id' volume-import missing volumeName"
            verify_digest "$path" "$sha"
            have_podman || die "podman not installed but layer '$id' needs volume-import"
            log "podman volume import '$id' -> $vol ($artifact)"
            $PODMAN volume rm -f "$vol" >/dev/null 2>&1 || true
            $PODMAN volume create "$vol" >/dev/null
            cat_tar "$path" | $PODMAN volume import "$vol" - || die "volume import failed for $vol"
            touch "$marker" ;;

        overlay)
            path="$LAYERS_DIR/$artifact"; [ -f "$path" ] || die "overlay artifact missing: $path"
            verify_digest "$path" "$sha"
            log "extracting overlay '$id' ($artifact) over /"
            cat_tar "$path" | tar xf - -C /
            touch "$marker" ;;

        *) die "unknown applyMode '$mode' for layer '$id'" ;;
    esac
done

# --- Normalize line endings + perms on scripts overlays dropped ---
for f in init.sh boot.sh activate.sh autostart.sh start-local.sh; do
    [ -f "/opt/ikuku/$f" ] && { sed -i 's/\r$//' "/opt/ikuku/$f" 2>/dev/null; chmod +x "/opt/ikuku/$f" 2>/dev/null; }
done

log "all layers applied. Handing off to the composer."

# --- Hand off to the idempotent boot/compose engine ---
if [ -f /opt/ikuku/boot.sh ]; then
    log "running /opt/ikuku/boot.sh"
    bash /opt/ikuku/boot.sh
elif [ -f /opt/ikuku/docker-compose.yml ]; then
    log "running podman-compose up -d"
    ( cd /opt/ikuku && ${IKUKU_COMPOSE:-podman-compose} up -d )
fi

log "compose done. ERPNext will come up in the background; Kiro MC launches via activate.sh."
exit 0
