# Ground Truth: where the ikuku distro's weight actually lives

Investigation to decide **Strategy B** (thin standard-Ubuntu base + a relocatable
app layer) vs **Strategy A** (ship the whole 12 GB pre-composed vhdx).

Method: mounted the shipping distro's ext4 **offline** (no Windows needed):
`qemu-nbd --read-only -f vhdx ikuku-fixed.vhdx` → `/dev/nbd0` → `/mnt/ikuku-distro`.
All figures below are apparent sizes from that mount (11.9 GiB actual on disk).

## The headline finding

**ikuku is ALREADY a thin-base + container-payload design.** The WSL distro itself
is essentially stock **Ubuntu 24.04 + podman**. Every heavy, app-specific thing lives
either in podman's store or as bundled binaries. `/home/frappe` on the host distro is
**empty** — the ERPNext bench exists *only inside the container* (volume-mounted).

That single fact demolishes the feared relocation hazard (see venv, below).

## Size map

| Root | Size | What it is | In stock Ubuntu? |
|---|---|---|---|
| `/var/lib/containers` | **8.0 G** | podman store — **the real payload** | no (added) |
| &nbsp;&nbsp;↳ `storage/overlay` | 6.3 G | 3 images: `frappe/bench:latest`, `mariadb:10.8`, `redis:alpine` | no |
| &nbsp;&nbsp;↳ `storage/volumes/ikuku_frappe-bench` | 1.4 G | real bench: `apps/ env/ sites/` | no |
| &nbsp;&nbsp;↳ `storage/volumes/ikuku_mariadb-data` | 319 M | seeded ERPNext DB | no |
| `/usr/local/bin/kiro-cli*` | **773 M** | `kiro-cli` 109M + `kiro-cli-chat` 664M | no |
| `/opt/ikuku/shared/kiro-cli*` | **772 M** | **DUPLICATE** of kiro + `bind.tar.gz` (76K) | no |
| `/usr` | 1.2 G | base Ubuntu + apt podman stack (~37M) | mostly yes |
| everything else | ~0.5 G | base Ubuntu | yes |

## The three questions we came to answer

### 1. Does the python venv's hardcoded absolute paths block relocation? → **NO.**

The venv is full of baked-in absolute paths — 66 files in `env/bin/` contain
`/home/frappe/frappe-bench`, `pyvenv.cfg` points at `/home/frappe/.pyenv/3.14.2`,
shebangs are `#!/home/frappe/frappe-bench/env/bin/python`.

**But every one of those paths is *inside the container*.** `docker-compose.yml`
mounts the bench volume at a fixed target:

```yaml
volumes:
  - frappe-bench:/home/frappe/frappe-bench   # ALWAYS this path, inside the container
```

The container namespace makes `/home/frappe/frappe-bench` constant no matter where the
**host** distro stores the volume data. The host never resolves those paths. So the
classic venv-relocation trap **does not apply** — the container already gives us the
stable prefix that the `/opt/ikuku/base` + symlink trick was trying to manufacture.

### 2. Can the podman store be relocated? → **YES, cleanly (config, not symlink).**

- Driver: **overlay** (native/fuse-overlayfs). The `overlay/l/` short-link dir uses
  **relative** short names, not absolute paths.
- No explicit `graphroot` in `/etc/containers/storage.conf` → default
  `/var/lib/containers/storage`.
- Relocation is a **one-line `storage.conf` change** (`graphroot = /opt/ikuku/base/...`),
  which podman fully supports — *not* a fragile symlink of the store dir.

So the store is movable, but the right lever is `graphroot`, not the symlink trick.

### 3. Is there waste we can cut? → **YES, ~0.8–1.5 GB of pure duplication.**

kiro is carried **twice** on the host (`/usr/local/bin` **and** `/opt/ikuku/shared`,
773M each), and `init.sh` copies it a **third** time into the container's
`/home/frappe/.local/bin`. `kiro-cli-chat` alone is 664 MB. Keeping a single copy and
symlinking/bind-mounting the rest saves ~773 MB immediately, ~1.5 GB if the container
copy is eliminated too.

## Verdict on the "/opt/ikuku/base + symlink" trick

The user's instinct — confine the app into one relocatable subtree, link it into the
main hierarchy, and note that frappe lives in only a handful of places — is **correct,
and the reality is even friendlier than hoped**:

- The "handful of places" is genuinely small at the **host** level: `/var/lib/containers`
  (the store), `/usr/local/bin` (kiro), `/opt/ikuku` (control scripts + bundled binaries).
  That's it. Everything else is stock Ubuntu.
- The scary part (venv abs-paths) is **already encapsulated by the container**, so no
  symlink gymnastics are needed for it at all.
- The store relocates via `graphroot`; kiro relocates trivially (single binaries).

**But the sharper conclusion:** because ikuku is *already* thin-base + container-payload,
Strategy B doesn't even need the elaborate symlink-relocation scheme. The clean B is:

> **B = standard Ubuntu (from `wsl --install`) + an app layer that carries the 3 podman
> images + the 2 volumes + ONE copy of kiro, dropped into place and registered via a
> `graphroot` (or default `/var/lib/containers`) + `podman load` / volume import.**

The app-layer weight is honestly **~8.8 GB uncompressed** (8.0 G store, but shipped as
image tars it's ~6 G compressed) + 0.77 G kiro — call it **~6–7 GB compressed**, vs the
12 GB fat vhdx. Not a massive shrink, but B wins decisively on **failure resilience**
(smaller resumable artifacts, standard Ubuntu path) and **reuse** (the base Ubuntu +
the 3 stock images are shared across every prospect; only the 1.7 GB of volumes are
prospect/app-specific).

**Go/no-go: GO for B is viable** — with two design refinements over the naive plan:
1. Move the podman store via `storage.conf graphroot`, not a symlink.
2. Deduplicate kiro to a single copy (saves ~0.8–1.5 GB regardless of A or B).

Strategy A (fat vhdx) stays as the always-works fallback.
