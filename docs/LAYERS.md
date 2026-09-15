# ikuku Layered Delivery

## Why

The prospect eval-kit used to ship as one monolithic ~12 GB `.vhdx` — the whole
Ubuntu/WSL distro dumped as a single blob. That defeats the goal (fast prospect
install) and is a dead brick: nothing is reusable. Every prospect = a fresh 12 GB
blob rebuilt from scratch, re-downloaded, re-imported.

The layered model treats a prospect distro like OCI/Docker image layers, but at the
WSL-distro level. Layers stack, in order, to assemble a working prospect-specific
ERPNext. The heavy, universal layers travel **once per machine** (cached); only the
thin per-prospect diff ships each time. Resellers mix-and-match and **reuse** layers
across prospects.

The WSL2 install itself (enabling the feature, installing the kernel) is already
solved by `install.ps1` + `shared/wsl-setup.ps1` and is **reused untouched**.

## The four layers

Layers stack low → high. Higher layers override/extend lower ones. Composition
happens **inside the guest at first boot** (model A): the installer imports the
cached base distro once, then untars the higher layers over the top in order and
runs the existing idempotent composer (`init.sh` / `activate.sh`).

| # | Layer      | Contents                                                              | Built from (existing seam)                                   | Size    | Cache scope        |
|---|------------|-----------------------------------------------------------------------|--------------------------------------------------------------|---------|--------------------|
| 0 | `base`     | Ubuntu rootfs + podman + `frappe` user + container **images**         | `wsl-setup.ps1` rootfs + `bundle/img-*.tar`                  | ~heavy  | once per machine   |
| 1 | `app`      | ERPNext bench + bind + kiro-cli binaries + training content (volumes) | `bundle/bench-dump.tar.zst` + `mariadb-dump.tar.zst` + `shared/` | heavy   | once per machine   |
| 2 | `vertical` | Industry preset: `seed.repl` records, future BOM/tax presets          | `seed.repl` (per-industry variant)                          | ~KB     | reuse per industry |
| 3 | `prospect` | `ikuku.conf` (name, OTP, endpoint) + `niche-context.md`               | those two files                                              | ~KB     | per prospect       |

Layer boundaries fall on artifact seams that already exist in the reseller build
path — nothing new is invented, the existing collapsed pipeline is just split into
discrete, addressable artifacts.

### What "cache once per machine" means

`base` and `app` are **content-addressed** (sha256 of the tar). The installer keeps
a local cache at `C:\ikuku\cache\<sha256>.tar`. If a prospect kit references a
`base`/`app` layer whose digest is already cached, it is **not** re-downloaded or
re-shipped — the installer reuses it. Two prospects on the same industry that pin
the same `base`+`app`+`vertical` differ only by the tiny `prospect` layer.

## Manifest

Every prospect kit carries a `layers.json` manifest describing the ordered stack.
Schema (`docs/layers.schema.json`):

```json
{
  "schemaVersion": 1,
  "kit": "al-souk-travel",
  "distro": "ikuku",
  "createdUtc": "2026-08-17T00:00:00Z",
  "layers": [
    {
      "id": "base",
      "order": 0,
      "role": "base",
      "artifact": "base-ubuntu-podman.tar.zst",
      "sha256": "…",
      "size": 0,
      "cache": "machine",
      "applyMode": "import",
      "description": "Ubuntu rootfs + podman + frappe user + container images"
    },
    {
      "id": "app-erpnext-v16",
      "order": 1,
      "role": "app",
      "artifact": "app-erpnext-v16.tar.zst",
      "sha256": "…",
      "size": 0,
      "cache": "machine",
      "applyMode": "overlay",
      "description": "ERPNext bench + bind + kiro-cli + training volumes"
    },
    {
      "id": "vertical-travel",
      "order": 2,
      "role": "vertical",
      "artifact": "vertical-travel.tar.zst",
      "sha256": "…",
      "size": 0,
      "cache": "industry",
      "applyMode": "overlay",
      "description": "Travel/TMC seed records + presets"
    },
    {
      "id": "prospect-al-souk",
      "order": 3,
      "role": "prospect",
      "artifact": "prospect-al-souk.tar.zst",
      "sha256": "…",
      "size": 0,
      "cache": "none",
      "applyMode": "overlay",
      "description": "Al Souk ikuku.conf (name/OTP) + niche-context.md"
    }
  ]
}
```

### Field semantics

- **`order`** — ascending apply order. The composer applies layers strictly in this
  order; a higher layer may overwrite files from a lower one.
- **`role`** — `base | app | vertical | prospect`. Drives caching policy and which
  layers the reseller may swap.
- **`artifact`** — filename of the tarball, relative to the kit / cache root.
- **`sha256`** — content digest. Used for cache hits and integrity verification.
- **`cache`** — `machine` (cache under `C:\ikuku\cache`, reuse across all kits) |
  `industry` (reuse across prospects of the same vertical) | `none` (never cached,
  always ships).
- **`applyMode`**:
  - `import` — the layer **is** the distro rootfs; applied via `wsl --import`
    (`--vhd` when the artifact is a `.vhdx`). Exactly one layer (the `base`) uses
    this and it must be `order: 0`.
  - `overlay` — the layer's tar is extracted **over the running distro's
    filesystem** into `/` (its paths are rooted at the distro root, e.g.
    `opt/ikuku/…`, `home/frappe/…`). Applied by the in-guest composer.

## Apply flow (model A, first boot)

```
install.ps1
  ├─ reuse WSL2 install as-is (wsl-setup.ps1)      ← unchanged
  ├─ read layers.json
  ├─ for each layer where cache != none:
  │     if C:\ikuku\cache\<sha256>.tar missing → copy from kit (or download)
  ├─ import base (order 0, applyMode=import)         → wsl --import ikuku …
  └─ hand the ordered overlay layers to the guest:
        copy overlay tars into the distro, then
        wsl -d ikuku -u root -- bash /opt/ikuku/apply-layers.sh
              │
              ├─ for each overlay layer in order:
              │     tar -xf <layer>.tar -C /        (extract over rootfs)
              ├─ run the existing composer: init.sh path re-runs idempotently
              │     (kiro-cli/bind refresh, OTP activate, seed.repl, niche-context)
              └─ activate.sh  → niche-aware Kiro MC
```

Because `init.sh` and `activate.sh` are already idempotent, re-running them after
each overlay is safe. Applying `vertical` then `prospect` yields exactly the same
end state the monolithic vhdx produced — but the base+app never re-ship.

### Fallback

If `layers.json` is absent, `install.ps1` falls back to the legacy single-artifact
prospect path (find a lone `*.vhdx` / `*wsl*.tar` and import it). This keeps existing
monolithic kits working during the transition.

## Reuse in practice

- **Second prospect, same industry** → ship only `prospect-*.tar.zst` (KB). Installer
  reuses cached `base` + `app` + `vertical`.
- **Second prospect, new industry** → ship `vertical-*.tar.zst` + `prospect-*.tar.zst`.
  Base + app still reused.
- **App upgrade (new ERPNext)** → bump `app` layer digest; base still reused.

Usage will refine the exact layer boundaries over time; the manifest's `order` +
`role` + content-addressing are the stable contract.


---

# Strategy B (recommended): standard-Ubuntu base + podman app layers

Strategy A (above) ships the whole distro as one ~12 GB `.vhdx`. Ground-truth
investigation (`docs/GROUND-TRUTH-layers.md`) showed ikuku is *already* thin-Ubuntu +
container-payload, and a measured build (`docs/STRATEGY-B-results.md`) confirmed B is
~4–5× lighter for the first prospect, ~30× lighter for repeats, and more failure-
resilient. **B is the recommended primary path; A stays as the offline fallback.**

## B layers

manifest `schemaVersion: 2`, `strategy: "B"`. Layers, in apply order:

| # | id | role | applyMode | artifact | cache | reuse |
|---|----|------|-----------|----------|-------|-------|
| 0 | `base-ubuntu` | base | `wsl-install` | — (pulled by `wsl --install -d Ubuntu`) | — | every machine |
| 1 | `app-images` | app | `podman-load` | `app-images.tar.zst` (frappe/bench + mariadb + redis) | machine | **every prospect** |
| 2 | `kiro` | kiro | `overlay` | `kiro.tar.zst` (single kiro-cli + kiro-cli-chat + bind) → `/opt/ikuku/shared` | machine | **every prospect** |
| 3 | `vertical-<x>` | vertical | `volume-import` | `vol-frappe-bench.tar.zst` → volume `ikuku_frappe-bench` | industry | per industry |
| 4 | `prospect-<x>-db` | prospect | `volume-import` | `vol-mariadb-data.tar.zst` → volume `ikuku_mariadb-data` | none | per prospect |
| 5 | `prospect-<x>` | prospect | `overlay` | `prospect-<x>.tar.zst` (`ikuku.conf` + `niche-context.md` + `seed.repl`) → `/opt/ikuku` | none | per prospect |

The **base is not shipped** — it is Microsoft's fast, resumable `wsl --install -d Ubuntu`.
The **app-images** (5.63 GB frappe/bench + mariadb + redis, all stock) and **kiro** are
cached by content digest under `C:\ikuku\cache` and reused by *every* prospect. Only the
volumes (~360 MB compressed) and the tiny prospect overlay ship per prospect.

## B applyModes

- **`wsl-install`** — the base. Installer runs `wsl --install -d <wslDistro>` (default
  `Ubuntu`), then `apt-get install podman podman-compose`. No artifact.
- **`podman-load`** — artifact is a `podman save` multi-image tar; composer runs
  `podman load -i <artifact>` into the **default** store `/var/lib/containers/storage`.
- **`volume-import`** — artifact is a `podman volume export` tar; composer runs
  `podman volume create <volumeName>` + `podman volume import <volumeName> <artifact>`.
- **`overlay`** — files extracted over the distro root (kiro binaries → `/opt/ikuku/shared`;
  prospect config → `/opt/ikuku`).

## Why not relocate the store (graphroot)?

Measured: podman's libpod bolt DB hardcodes the original graphroot; `podman --root <other>`
fails with *"database configuration mismatch"*. So B uses the **default** store path,
which is exactly where a fresh `wsl --install` Ubuntu's podman looks — no relocation
needed. Also: always ship via `podman save`/`volume export` (portable, lands in a clean
store), **never** a raw copy of a live store (it carries un-removable phantom containers).

## B apply flow (first boot)

```
install.ps1 (B branch)
  ├─ wsl --install -d Ubuntu        (base; may reboot+resume — reused untouched)
  ├─ apt-get install podman podman-compose
  ├─ cache machine-scope layers (app-images, kiro) under C:\ikuku\cache by sha256
  ├─ copy layer artifacts + manifest into the distro /opt/ikuku/layers
  └─ wsl -d Ubuntu -u root -- bash /opt/ikuku/apply-layers.sh
        ├─ podman load app-images.tar.zst            (cache HIT skips re-ship)
        ├─ extract kiro.tar.zst → /opt/ikuku/shared  (one copy)
        ├─ volume-import vol-frappe-bench, vol-mariadb-data
        ├─ extract prospect overlay → /opt/ikuku (ikuku.conf, niche, seed.repl)
        └─ podman-compose up → init.sh (bench start) → activate.sh (niche Kiro)
```

Idempotent (sha markers) and offline-safe (no network needed to apply; OTP activation
reaches the endpoint if online). Repeat prospects hit the cache for app-images + kiro
and only ship the thin vertical/prospect layers — this is the reuse the two-evalkit
test (Al Souk + KapadiWala) exercises.
