#!/bin/bash
# build-layers.sh — split a working ikuku distro into composable layer tars.
#
# Produces the four-layer stack described in docs/LAYERS.md:
#   0 base     — Ubuntu rootfs + podman + frappe user + container images   (applyMode=import)
#   1 app      — ERPNext bench + bind + kiro-cli + training + site volume  (applyMode=overlay)
#   2 vertical — industry seed.repl + presets                             (applyMode=overlay)
#   3 prospect — ikuku.conf + niche-context.md                            (applyMode=overlay)
#
# and writes a populated layers.json manifest (sha256 + size filled in).
#
# Design contract (see docs/LAYERS.md):
#   - The base layer IS the rootfs. It ships as a .vhdx (preferred; wsl --import --vhd)
#     or a rootfs .tar. It is produced OUTSIDE this script (wsl --export) and merely
#     referenced here; this script hashes it and records it in the manifest.
#   - overlay tars are rooted at the DISTRO ROOT so the guest composer can
#     `tar -xf layer.tar -C /`. Paths therefore look like ./opt/ikuku/... and
#     ./home/frappe/frappe-bench/...
#
# Usage:
#   bash build-layers.sh \
#       --kit al-souk-travel \
#       --base   /path/to/base-ubuntu-podman.vhdx \
#       --bench  /path/to/frappe-bench-export \      (dir OR bench-dump.tar[.zst])
#       --mariadb /path/to/mariadb-dump.tar[.zst] \  (optional; app-layer DB volume)
#       --shared /projects/sandbox/ikuku/shared \    (kiro-cli, bind.tar.gz, next-sale.bundle)
#       --seed   /path/to/seed.repl \                (vertical layer)
#       --vertical-id vertical-travel \
#       --conf   /path/to/ikuku.conf \               (prospect layer)
#       --niche  /path/to/niche-context.md \         (prospect layer)
#       --out    ./layers
#
# Any layer whose inputs are omitted is skipped (and left out of the manifest),
# so you can rebuild just the thin vertical/prospect layers for a repeat prospect.

set -euo pipefail

# ---- defaults ----
KIT=""
DISTRO="ikuku"
BASE_ARTIFACT=""
BENCH_SRC=""
MARIADB_SRC=""
SHARED_DIR=""
SEED_SRC=""
VERTICAL_ID="vertical-generic"
CONF_SRC=""
NICHE_SRC=""
OUT_DIR="./layers"
APP_ID="app-erpnext-v16"

# ---- arg parse ----
while [ $# -gt 0 ]; do
    case "$1" in
        --kit) KIT="$2"; shift 2 ;;
        --distro) DISTRO="$2"; shift 2 ;;
        --base) BASE_ARTIFACT="$2"; shift 2 ;;
        --bench) BENCH_SRC="$2"; shift 2 ;;
        --mariadb) MARIADB_SRC="$2"; shift 2 ;;
        --shared) SHARED_DIR="$2"; shift 2 ;;
        --seed) SEED_SRC="$2"; shift 2 ;;
        --vertical-id) VERTICAL_ID="$2"; shift 2 ;;
        --conf) CONF_SRC="$2"; shift 2 ;;
        --niche) NICHE_SRC="$2"; shift 2 ;;
        --app-id) APP_ID="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -z "$KIT" ] && { echo "ERROR: --kit is required" >&2; exit 2; }
mkdir -p "$OUT_DIR"

# ---- helpers ----
have_zstd() { command -v zstd >/dev/null 2>&1; }
COMPRESS_EXT="tar.zst"
compress() {  # compress <in.tar> -> writes <in>.zst (or gz) and removes the .tar
    local f="$1"
    if have_zstd; then
        zstd -q -f --rm -T0 "$f" -o "$f.zst"
        echo "$f.zst"
    else
        gzip -f "$f"
        echo "$f.gz"
    fi
}
sha256() { sha256sum "$1" | cut -d' ' -f1; }
filesize() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }

# Accumulate manifest layer objects here (JSON fragments).
LAYER_JSON=()
add_layer() { # add_layer <id> <order> <role> <artifact-path> <cache> <applyMode> <desc>
    local id="$1" order="$2" role="$3" path="$4" cache="$5" mode="$6" desc="$7"
    local art sha sz
    art="$(basename "$path")"
    sha="$(sha256 "$path")"
    sz="$(filesize "$path")"
    echo "  + layer '$id' ($role, $mode): $art  [$sz bytes, sha ${sha:0:12}…]"
    LAYER_JSON+=("$(cat <<JSON
    {
      "id": "$id",
      "order": $order,
      "role": "$role",
      "artifact": "$art",
      "sha256": "$sha",
      "size": $sz,
      "cache": "$cache",
      "applyMode": "$mode",
      "description": "$desc"
    }
JSON
)")
}

echo "=== ikuku build-layers: kit '$KIT' → $OUT_DIR ==="

# ---------------------------------------------------------------------------
# Layer 0: base (import). Provided pre-built; we reference + hash it.
# ---------------------------------------------------------------------------
if [ -n "$BASE_ARTIFACT" ]; then
    [ -f "$BASE_ARTIFACT" ] || { echo "ERROR: --base '$BASE_ARTIFACT' not found" >&2; exit 1; }
    base_dest="$OUT_DIR/$(basename "$BASE_ARTIFACT")"
    if [ "$(readlink -f "$BASE_ARTIFACT")" != "$(readlink -f "$base_dest" 2>/dev/null || echo /nonexistent)" ]; then
        echo "  copying base artifact into $OUT_DIR (may be large)…"
        cp -f "$BASE_ARTIFACT" "$base_dest"
    fi
    add_layer "base" 0 "base" "$base_dest" "machine" "import" \
        "Ubuntu rootfs + podman + frappe user + preloaded container images"
else
    echo "  (skipping base layer — no --base given)"
fi

# ---------------------------------------------------------------------------
# Layer 1: app (overlay). frappe-bench + shared binaries + (optional) mariadb volume.
# Staged into a rootfs-relative tree so it extracts cleanly with `tar -xf -C /`.
# ---------------------------------------------------------------------------
if [ -n "$BENCH_SRC" ] || [ -n "$SHARED_DIR" ]; then
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' EXIT

    # frappe-bench → ./home/frappe/frappe-bench
    if [ -n "$BENCH_SRC" ]; then
        mkdir -p "$stage/home/frappe/frappe-bench"
        if [ -d "$BENCH_SRC" ]; then
            echo "  staging bench from dir $BENCH_SRC …"
            tar cf - -C "$BENCH_SRC" . | tar xf - -C "$stage/home/frappe/frappe-bench"
        elif [[ "$BENCH_SRC" == *.zst ]]; then
            echo "  staging bench from $BENCH_SRC …"
            zstd -dc "$BENCH_SRC" | tar xf - -C "$stage/home/frappe/frappe-bench"
        elif [[ "$BENCH_SRC" == *.gz ]]; then
            gunzip -c "$BENCH_SRC" | tar xf - -C "$stage/home/frappe/frappe-bench"
        else
            tar xf "$BENCH_SRC" -C "$stage/home/frappe/frappe-bench"
        fi
    fi

    # shared binaries → ./opt/ikuku/shared
    if [ -n "$SHARED_DIR" ]; then
        echo "  staging shared/ (kiro-cli, bind, training) …"
        mkdir -p "$stage/opt/ikuku/shared"
        for f in kiro-cli kiro-cli-chat bind.tar.gz next-sale.bundle; do
            [ -f "$SHARED_DIR/$f" ] && cp -f "$SHARED_DIR/$f" "$stage/opt/ikuku/shared/"
        done
    fi

    # mariadb site volume → ./opt/ikuku/app-volumes/mariadb-dump.tar
    # (the composer imports this into the podman named volume; kept as a nested
    #  tar so it is volume-format agnostic)
    if [ -n "$MARIADB_SRC" ]; then
        echo "  staging mariadb volume dump …"
        mkdir -p "$stage/opt/ikuku/app-volumes"
        cp -f "$MARIADB_SRC" "$stage/opt/ikuku/app-volumes/$(basename "$MARIADB_SRC")"
    fi

    app_tar="$OUT_DIR/${APP_ID}.tar"
    echo "  packing app layer …"
    tar cf "$app_tar" -C "$stage" .
    app_art="$(compress "$app_tar")"
    add_layer "$APP_ID" 1 "app" "$app_art" "machine" "overlay" \
        "ERPNext bench + bind + kiro-cli + training content + mariadb site volume"

    rm -rf "$stage"; trap - EXIT
else
    echo "  (skipping app layer — no --bench/--shared given)"
fi

# ---------------------------------------------------------------------------
# Layer 2: vertical (overlay). seed.repl → ./opt/ikuku/seed.repl
# ---------------------------------------------------------------------------
if [ -n "$SEED_SRC" ]; then
    [ -f "$SEED_SRC" ] || { echo "ERROR: --seed '$SEED_SRC' not found" >&2; exit 1; }
    stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/opt/ikuku"
    cp -f "$SEED_SRC" "$stage/opt/ikuku/seed.repl"
    v_tar="$OUT_DIR/${VERTICAL_ID}.tar"
    tar cf "$v_tar" -C "$stage" .
    v_art="$(compress "$v_tar")"
    add_layer "$VERTICAL_ID" 2 "vertical" "$v_art" "industry" "overlay" \
        "Industry vertical: seed.repl records + presets"
    rm -rf "$stage"; trap - EXIT
else
    echo "  (skipping vertical layer — no --seed given)"
fi

# ---------------------------------------------------------------------------
# Layer 3: prospect (overlay). ikuku.conf + niche-context.md → ./opt/ikuku/
# ---------------------------------------------------------------------------
if [ -n "$CONF_SRC" ] || [ -n "$NICHE_SRC" ]; then
    stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/opt/ikuku"
    [ -n "$CONF_SRC" ]  && { [ -f "$CONF_SRC" ]  || { echo "ERROR: --conf not found" >&2; exit 1; }; cp -f "$CONF_SRC"  "$stage/opt/ikuku/ikuku.conf"; }
    [ -n "$NICHE_SRC" ] && { [ -f "$NICHE_SRC" ] || { echo "ERROR: --niche not found" >&2; exit 1; }; cp -f "$NICHE_SRC" "$stage/opt/ikuku/niche-context.md"; }
    p_id="prospect-$KIT"
    p_tar="$OUT_DIR/${p_id}.tar"
    tar cf "$p_tar" -C "$stage" .
    p_art="$(compress "$p_tar")"
    add_layer "$p_id" 3 "prospect" "$p_art" "none" "overlay" \
        "Prospect $KIT: ikuku.conf (name/OTP/endpoint) + niche-context.md"
    rm -rf "$stage"; trap - EXIT
else
    echo "  (skipping prospect layer — no --conf/--niche given)"
fi

# ---------------------------------------------------------------------------
# Emit manifest
# ---------------------------------------------------------------------------
[ ${#LAYER_JSON[@]} -eq 0 ] && { echo "ERROR: no layers built — nothing to write" >&2; exit 1; }

manifest="$OUT_DIR/layers.json"
{
    echo "{"
    echo "  \"schemaVersion\": 1,"
    echo "  \"kit\": \"$KIT\","
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
echo "=== Done. Manifest: $manifest ==="
cat "$manifest"
