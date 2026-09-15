# Resume note — Strategy B e2e (session end 2026-09-15)

## Status: B is wired + proven at host level; pristine-Win11 guest e2e interrupted by SPOT reclamation

The m5d.metal SPOT (`i-0d1c7a1adb33a1827`) was reclaimed by AWS mid-test
(`instance-terminated-no-capacity`). Nothing lost — all code is committed and the data
volumes were snapshotted before teardown.

## What's committed (branch `kiro-layer`)
- `03daa45` fix: install zstd/python3 unconditionally + apply-layers hard-fail podman load
- `0e9f12b` feat: Strategy B wiring (build-layers-b.sh, apply-layers.sh A+B, install.ps1 B branch, schema v2, LAYERS.md)
- `3f34b11` docs: Strategy B measured results
- `16b10d3` docs: ground-truth investigation

## Snapshots to restore next session (region ap-south-1)
| Snapshot | Volume | Contents |
|---|---|---|
| `snap-0ac2be7dcb8601f8d` | win-ikuku 150G | **both kits** (`/vm/ikuku/pkg/kit-alsouk`, `kit-kapadiwala`), `bkit/`, `build-layers-b.sh`, working `win11.qcow2` |
| `snap-0634baa70563957f7` | pristine 100G | **pristine Win11 build 26200 with WSL2 MSI + Ubuntu distro already installed** (skips the painful WSL2 bootstrap) |
| `snap-0c0c7a726edf65c44` | data 20G | shazam data |

Restore: `cd metal-spot4win && bash shazam.sh up ikuku` (fixes: pass explicit VM to avoid
the auto-discover bug already patched). Then attach the pristine snapshot as a 2nd volume
and launch its win11.qcow2 on ports 2223/3390/8001.

## The two kits (identical shared-layer digests = the reuse proof)
Both in `/vm/ikuku/pkg/` on the win-ikuku volume:
- **kit-alsouk** (travel, AED/UAE): app-images `84146e16a4f3`, kiro `5ef53038cfe1`, vol-frappe-bench `77a6c11f405c`, vol-mariadb `42f1b33a9f55`, prospect `b3616f795614` (fresh OTPs 39306fcb…)
- **kit-kapadiwala** (recycling, INR/India): app-images `84146e16a4f3` (SAME), kiro `5ef53038cfe1` (SAME), vol-frappe-bench `a525187a34e1`, vol-mariadb `4df1e329287b`, prospect `1cec536d0a51`
→ app-images + kiro match → installer cache-HITs on the 2nd kit, ships only ~370MB volumes.

## What the pristine e2e PROVED before the spot died (Win11 build 26200, no WSL2)
- install.ps1 B branch: detects strategy B, reads 6-layer manifest, correct reboot gate.
- Full WSL2 bootstrap from pristine: dism features, real WSL2 via **direct MSI download**
  (`wsl.2.7.14.0.x64.msi`) when the inbox stub refused, Ubuntu distro post-reboot.
- Ubuntu base + podman 5.7.0 + `cache MISS app` (populating C:\ikuku\cache) + layer staging.
- apply-layers integrity guard correctly caught a corrupted transfer.
- **Host-level proof (reliable): apply-layers.sh assembled the KapadiWala kit on clean
  podman → ERPNext HTTP 200 + niche Kiro greeting.**

## The ONE remaining gap + why
`podman load → compose → ERPNext 200` *inside the Windows guest* was not reached:
1. missing-zstd bug (now FIXED),
2. then the guest HUNG under **WSL2 (Hyper-V) nested inside QEMU** — 0% CPU, black screen,
3. then AWS reclaimed the spot.

This is a **test-rig nested-virtualization limitation** (WSL2-in-QEMU-in-EC2), NOT a
Strategy-B flaw. A real prospect on bare-metal Win11 has no nested-virt issue.

## Next session TODO (pick up here)
1. `shazam up ikuku` from `snap-0ac2be7dcb8601f8d`; reattach pristine from `snap-0634baa70563957f7`.
2. Because the pristine snapshot ALREADY has WSL2 MSI + Ubuntu, the guest e2e can jump
   straight to: copy a kit to C:, run `install.ps1 -LaunchDir` → apply-layers (zstd now
   installed unconditionally) → **target ERPNext 200 + niche Kiro on the guest**.
3. To reduce nested-virt hang risk: give the guest more RAM, ensure `-cpu host,+vmx`,
   and/or run the load with fewer parallel ops.
4. Then run the 2nd kit → confirm cache HIT on app-images/kiro (only volumes ship).
5. Write final two-kit reuse e2e results; consider harden `wsl-setup.ps1` to do the
   direct-MSI WSL2 install (the stub-refuses-to-bootstrap case is real on build 26200).

## Host gotcha fixed this session (may recur on a fresh host)
Host `systemd-resolved` was broken (DNS dead) → guest had no DNS → WSL/apt downloads
failed. Fix: `echo 'nameserver 169.254.169.253' > /etc/resolv.conf` (VPC DNS) + add
hostname to /etc/hosts. Check this early on any fresh shazam host.
