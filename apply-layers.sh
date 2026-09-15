#!/bin/bash
# apply-layers.sh — in-guest composer for ikuku layered delivery (model A).
#
# Runs INSIDE the imported base distro at first boot. The base layer (order 0,
# applyMode=import) is already the rootfs — this script applies the higher overlay
# layers on top, in manifest order, then hands off to the existing idempotent
# composer (init.sh bench-exists path) and the niche-aware Kiro launcher (activate.sh).
#
# Contract with install.ps1 (see docs/LAYERS.md):
#   - install.ps1 imports the base, then drops the manifest + all overlay artifacts
#     into  /opt/ikuku/layers/  :
#         /opt/ikuku/layers/layers.json
#         /opt/ikuku/layers/<each overlay artifact>.tar[.zst|.gz]
#   - then runs:  wsl -d ikuku -u root -- bash /opt/ikuku/apply-layers.sh
#
# Idempotent: applying twice is safe. Each overlay records a marker under
#   /opt/ikuku/.layers-applied/<sha256>  so re-runs skip already-applied layers
#   unless --force is given.
#
# Offline-safe: no network needed to apply layers. (OTP activation inside
# init.sh/activate.sh reaches the auth endpoint if online; that is unchanged.)

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

# --- Parse manifest into ordered "order|role|artifact|sha256|applyMode" lines ---
mapfile -t LAYER_LINES < <(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
layers = sorted(m.get("layers", []), key=lambda l: l.get("order", 0))
for l in layers:
    print("|".join([
        str(l.get("order","")),
        l.get("role",""),
        l.get("artifact",""),
        l.get("sha256",""),
        l.get("applyMode",""),
    ]))
PY
)
[ "${#LAYER_LINES[@]}" -gt 0 ] || die "no layers in manifest"

# --- Extract one overlay archive over the rootfs (format-agnostic) ---
extract_overlay() {
    local art="$1" path="$LAYERS_DIR/$1"
    [ -f "$path" ] || die "overlay artifact missing: $path"
    case "$art" in
        *.tar.zst) if command -v zstd >/dev/null 2>&1; then zstd -dc "$path" | tar xf - -C / ;
                   else die "artifact $art is zstd but zstd not installed in guest"; fi ;;
        *.tar.gz)  tar xzf "$path" -C / ;;
        *.tgz)     tar xzf "$path" -C / ;;
        *.tar)     tar xf  "$path" -C / ;;
        *) die "unknown overlay artifact format: $art" ;;
    esac
}

# --- Apply overlays in order (skip base/import; skip already-applied) ---
log "manifest: $MANIFEST (${#LAYER_LINES[@]} layers)"
for line in "${LAYER_LINES[@]}"; do
    IFS='|' read -r order role artifact sha mode <<< "$line"
    if [ "$mode" = "import" ]; then
        log "layer '$role' (order $order) is the base rootfs — already imported, skipping"
        continue
    fi
    marker="$APPLIED_DIR/$sha"
    if [ "$FORCE" -eq 0 ] && [ -f "$marker" ]; then
        log "layer '$role' (order $order, ${sha:0:12}…) already applied — skipping"
        continue
    fi
    # Integrity: verify digest before extracting (skip if manifest sha is a placeholder)
    if [ -n "$sha" ] && ! echo "$sha" | grep -qE '^0{64}$'; then
        actual="$(sha256sum "$LAYERS_DIR/$artifact" | cut -d' ' -f1)"
        [ "$actual" = "$sha" ] || die "digest mismatch for $artifact (manifest $sha, actual $actual)"
    fi
    log "applying layer '$role' (order $order): $artifact"
    extract_overlay "$artifact"
    touch "$marker"
done

# --- App-layer side effect: import mariadb volume dump if the app layer shipped one ---
# The app overlay drops it at /opt/ikuku/app-volumes/mariadb-dump.tar[.zst|.gz].
# init.sh's bench-exists path recreates the site if the DB is missing, but restoring
# the dump preserves the seeded data without a rebuild.
VOL_DUMP="$(ls /opt/ikuku/app-volumes/mariadb-dump.tar* 2>/dev/null | head -1 || true)"
if [ -n "$VOL_DUMP" ] && [ ! -f "$APPLIED_DIR/.mariadb-imported" ]; then
    if command -v podman >/dev/null 2>&1; then
        log "restoring mariadb volume from $(basename "$VOL_DUMP")"
        podman volume create ikuku_mariadb-data >/dev/null 2>&1 || true
        case "$VOL_DUMP" in
            *.zst) zstd -dc "$VOL_DUMP" | podman volume import ikuku_mariadb-data - ;;
            *.gz)  gunzip -c "$VOL_DUMP" | podman volume import ikuku_mariadb-data - ;;
            *)     podman volume import ikuku_mariadb-data - < "$VOL_DUMP" ;;
        esac && touch "$APPLIED_DIR/.mariadb-imported" || log "mariadb import failed (non-fatal — init.sh will recreate the site)"
    else
        log "podman not on PATH yet — skipping volume import (init.sh will recreate the site)"
    fi
fi

# --- Normalize line endings + perms on the scripts the overlays dropped ---
for f in init.sh boot.sh activate.sh autostart.sh start-local.sh; do
    [ -f "/opt/ikuku/$f" ] && { sed -i 's/\r$//' "/opt/ikuku/$f" 2>/dev/null; chmod +x "/opt/ikuku/$f" 2>/dev/null; }
done

log "all layers applied. Handing off to the composer."

# --- Hand off to the existing idempotent boot/compose engine ---
# boot.sh (podman-compose up) runs init.sh inside the frappe container, which
# self-heals kiro-cli/bind, activates OTP, loads seed.repl and niche-context.
if [ -f /opt/ikuku/boot.sh ]; then
    log "running /opt/ikuku/boot.sh"
    bash /opt/ikuku/boot.sh
elif [ -f /opt/ikuku/docker-compose.yml ]; then
    log "running podman-compose up -d"
    ( cd /opt/ikuku && podman-compose up -d )
fi

log "compose done. ERPNext will come up in the background; Kiro MC launches via activate.sh."
exit 0
