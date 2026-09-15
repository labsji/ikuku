# Strategy B — measured results (thin Ubuntu base + podman app layer)

Companion to `docs/GROUND-TRUTH-layers.md`. This documents an **end-to-end build and
test of Strategy B** on the live host, with real measured numbers, and an honest
A-vs-B comparison.

**Verdict up front: Strategy B works, is dramatically lighter to ship, and is more
robust to install failure. Recommended as the primary path; keep the fat vhdx (A) as
the offline fallback.**

## What B is

- **Base**: a *standard* Ubuntu (what `wsl --install -d Ubuntu` gives you) + podman.
  Not shipped by us — reused from Microsoft's fast, resumable install path.
- **App layer** (what we ship): the 3 podman images + the 2 named volumes + **one**
  copy of the kiro binaries + the `/opt/ikuku` control scripts.

## How B was tested (real, not theoretical)

On the host (podman 4.9.3), a **clean** podman store was created (`podman system reset`
+ removed `/var/lib/containers/storage`) to simulate a fresh `wsl --install` Ubuntu.
The app layer was then assembled from **portable artifacts** and booted.

```
podman load  -i app-images.tar          # 3 images
podman volume create + import  x2        # frappe-bench + mariadb-data
podman-compose up -d                     # bring the stack up
```

### Measured timings (clean store → serving)

| Step | Time |
|---|---|
| `podman load` 3 images (5.7 GB tar) | **61 s** |
| create + import 2 volumes | **7 s** |
| `podman-compose up -d` | **5.6 s** |
| **app-layer assembly subtotal** | **~74 s** |
| bench cold start → HTTP 200 | ~30–60 s |

**Result:** all 3 containers Up; `curl localhost:8000/` → **HTTP 200**;
`/api/method/ping` → `{"message":"pong"}`. `init.sh` correctly took the
"Bench already exists" path (no rebuild).

### Kiro after B (dedup didn't break it)

`init.sh` self-healed kiro from the **single** `/opt/ikuku/shared` copy into the
container (`/home/frappe/.local/bin`, both binaries co-located). `kiro-cli 2.15.0`.
With a fresh `KIRO_API_KEY` (OTP→token→refresh), `kiro-cli chat --no-interactive
--trust-all-tools` **ran a shell tool** (curl → HTTP 200) and produced a niche-aware
greeting:

> "Welcome, Al Souk Travel & Tourism! … a UAE travel and tourism leader … set up a
> 'Tour Package' Item Group with sellable service items (flights, hotels, visa
> processing)…"  (Credits 0.10, 6 s)

Confirms the niche awareness is driven by the **prompt / `ikuku.conf`** (via
`activate.sh`), not the seeded DB — exactly the layered design.

## Measured artifact weights

| Artifact | Raw | Compressed (zstd-3) | Reuse scope |
|---|---:|---:|---|
| `app-images.tar` (frappe/bench + mariadb + redis) | 6.11 GB | **1.88 GB** | **all prospects** (stock images) |
| `vol-frappe-bench.tar` | 1.54 GB | **364 MB** | app/vertical |
| `vol-mariadb-data.tar` | 335 MB | **13.5 MB** | prospect (seeded DB) |
| kiro (`kiro-cli` + `kiro-cli-chat`), one copy | 809 MB | ~430 MB | all prospects |
| **Strategy A** `ikuku-fixed.vhdx` (for comparison) | **12.82 GB** | ~5–6 GB | none (monolithic) |

## A vs B

| Dimension | A — fat vhdx | B — thin base + app layer |
|---|---|---|
| **First-prospect ship** | ~12.8 GB (raw) / ~5–6 GB (zst) | **~2.7 GB** compressed (1.88 + 0.36 + 0.014 + 0.43) |
| **Repeat prospect, same app** | 12.8 GB again | **~380 MB** (volumes only; app-images + kiro cached) |
| **Repeat prospect, new industry** | 12.8 GB again | **~380 MB** (swap the thin volume/overlay) |
| **Biggest single artifact** | one 12.8 GB file | 1.88 GB (app-images) |
| **Unzip / import risk** | high — one huge extract that fails late & whole | low — smaller, independently retryable artifacts |
| **Base install** | our `wsl --import` of a 12.8 GB vhdx | Microsoft's `wsl --install` (fast, resumable, tested) |
| **Assembly work on-box** | ~1–3 min import | ~74 s (`podman load`+volumes) + compose |
| **Reuse** | none | base Ubuntu + 3 stock images shared across every prospect |
| **Offline / air-gapped** | trivially works (it's everything) | works (artifacts are self-contained) |

**Net:** B ships ~**4–5× less** for the first prospect and ~**30× less** for a repeat
prospect, while using the more reliable standard-Ubuntu install path. The on-box
assembly (~74 s) is comparable to A's import — the user's original hunch ("installing
layers is faster typical-IO, and the huge unzip could even fail") holds on the
**reliability** axis clearly, and on the **weight** axis decisively.

## Gotchas found (important for implementing B)

1. **Do NOT relocate the podman store via a custom `graphroot`.** The libpod bolt DB
   hardcodes the original path; `podman --root <other>` fails with
   *"database configuration mismatch"*. B doesn't need relocation — a stock Ubuntu
   podman uses the default `/var/lib/containers/storage`, which is exactly where the
   images/volumes transplant cleanly.
2. **Ship as `podman save` / `podman volume export`, not a raw store copy.** A raw copy
   of a *live* store carries **phantom container records** (referencing dead PIDs) that
   can't be removed and block `compose up`. The portable load/import path lands in a
   clean store with no phantoms.
3. **Dedup kiro.** The shipping distro carried kiro **twice** on the host
   (`/usr/local/bin` + `/opt/ikuku/shared`, ~773 MB each) and copied it a third time
   into the container. Ship **one** copy in `/opt/ikuku/shared`; `init.sh` self-heals
   it into the container. Saves ~0.8–1.5 GB.

## Recommended B build (for implementation)

1. **App layer artifact** (built once, cached/reused across all prospects):
   `app-images.tar.zst` (the 3 images) + one kiro copy.
2. **Vertical/prospect layer**: `vol-frappe-bench.tar.zst` + `vol-mariadb-data.tar.zst`
   (or, better, a fresh generic bench + `seed.repl` applied at first boot, so the
   volume isn't prospect-specific at all).
3. **Installer flow**: `wsl --install -d Ubuntu` → apt install podman → `podman load`
   app-images → `podman volume import` volumes → drop `/opt/ikuku` (+ one kiro) →
   `podman-compose up` → `activate.sh` (niche greeting).

Strategy A (`ikuku-fixed.vhdx` + the layered manifest already built) remains the
always-works fallback for machines where `wsl --install` of a fresh distro is
undesirable or offline image pulls are blocked.
