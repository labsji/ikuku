# ikuku (kiro-layer) — Specification & Style Guide

> **Branch scope.** `main` is the public, open-source layer (fresh-build ERPNext, no Kiro).
> **`kiro-layer` is where the reseller/prospect action lives** — the evalkit dump-import flow,
> the tray app, Kiro-as-master-of-ceremonies, and the USB-delivered prospect experience.
> This file is the source of truth for **kiro-layer** behavior. Public-layer specs (SPEC-I01…I07)
> live in `SPEC.md` on `main`; the kiro-layer-relevant ones are mirrored below.

---

## The distribution chain (why this branch exists)

```
Reseller  → configures a few verticals
  → hands one vertical to a Reseller Delegate
    → Delegate configures many prospects/week → ships an evalkit .zip on a USB
      → Prospect runs it locally → tray engages them while WSL → podman → Kiro come up
```

The **evalkit dump-import path is the reseller product.** Fresh-build (on `main`) is the
self-service / open-source path for a different audience.

---

## Spec Entries (kiro-layer)

### SPEC-I08: Evalkit Dump-Import Mode (fast install)
**Behavior:** Two install modes, auto-selected. If a reseller's evalkit — a preconfigured WSL
dump named `*wsl*.tar` — sits alongside the exe, the installer **imports the dump** (~2–5 min,
no build). Otherwise it **builds from scratch** (fresh-build). The delegate builds the evalkit;
the prospect just runs the exe with the tar beside it.
**Implementation:** `ikuku-installer.nsi` → `IfFileExists "$EXEDIR\*wsl*.tar"` branches to
`install-prospect.ps1` (dump-import) or `install.ps1` (fresh-build). Prospect-mode detection runs
BEFORE the WSL2 gate. Evalkit zip: `*wsl*.tar` + `ikuku.conf` + `ikuku-tray.exe` (+ `seed.repl`).
**Test:** exe with `*wsl*.tar` → ERPNext live in <5 min, no build. exe with no tar → fresh build.

### SPEC-I09: Desktop Tray App (evalkit path only — by design)
**Behavior:** `ikuku-tray.exe` is installed **only by the evalkit dump-import path**. Its job is
**prospect engagement during the boot wait** — status ("installing → active", phase tooltips,
progress balloons) while WSL, then podman, then Kiro come up, so the prospect isn't staring at
nothing. Fresh-build has no tray (users there use the in-WSL `train` alias).
**Implementation:** `install-prospect.ps1` copies `ikuku-tray.exe` (bundled in the evalkit zip),
adds a Startup shortcut, launches it; the tray independently polls ERPNext for readiness. CI
fetches `ikuku-tray.exe` from S3 before the NSIS build. Guarded by `Test-Path` — silently skipped
if absent.
**Test:** evalkit install → tray appears, reflects status until ERPNext ready. Fresh-build → no
tray (expected, not a defect).

### SPEC-I10: Kiro as Master of Ceremonies
**Behavior:** On the evalkit/prospect box, Kiro comes up after WSL+podman and drives the
system-aware onboarding (seed.repl + niche-context.md loaded on first boot; niche-pattern.md
injected into Kiro instructions when present).
**Implementation:** first-boot hooks load `seed.repl` / `niche-context.md`; `.kiro` dir chowned
to the frappe user; kiro-cli bundled from S3 on the `kiro-layer` release.
**Test:** first boot → Kiro greets with the vertical's niche context, not a blank agent.

---

## Known recurring pitfalls (guard against these — they keep coming back)

An audit of kiro-layer history found the SAME classes of bug re-fixed many times. Treat these as
hard rules for ANY new `.ps1` or shell script; ideally add a CI lint that fails on them.

### PIT-1: PowerShell 5.1 under NSIS is strict (re-fixed 5+ times, Apr–Aug)
The installer runs under **PS 5.1** inside NSIS. It does **not** accept:
- `&&` or `||` between commands → use `;` or separate lines / `if` blocks.
- em-dashes or any non-ASCII in `.ps1` → ASCII only.
- parenthesized expressions inside `Write-Host ... -ForegroundColor` → assign to a var first.
Every recurrence was a *new* script reintroducing one of these. **Rule:** no `&&`/`||`, no
non-ASCII, no parenthesized `Write-Host` args in any `.ps1`.

### PIT-2: CRLF from Windows breaks shell scripts in WSL (re-fixed 4+ times)
Scripts authored on Windows carry `\r`; bash in WSL chokes. **Rule:** strip `\r` (use `tr -d '\r'`,
not `sed`) on every shell script copied into WSL (`init.sh`, `boot.sh`, `autostart.sh`,
`start-local.sh`, `activate.sh`).

### PIT-3: full.zip 2GB / bundle bloat (re-fixed a few times)
GitHub release assets cap at 2GB; volume dumps + duplicate bundles blew past it. **Rule:** ship
the large full/evalkit artifact via **S3**, not GitHub releases; don't double-bundle volume dumps
that are already baked into the WSL tar.

> **e2e status (MVP honesty):** the full evalkit flow has NOT yet been verified end-to-end on a
> pristine Windows 11 prospect box. Edits to date were made by Kiro *during* e2e attempts that
> kept getting cut short (spot-instance reclamation, attention drop-off). Treat the installer as
> "fixed in pieces, not yet green e2e." A clean-box e2e pass is the outstanding validation before
> leaning on it with real prospects — and is the single highest-leverage item for the reseller push.

---

## Adding New Specs
Same convention as `main`: `SPEC-INn: Title`, with **Behavior / Implementation / Test**, and
reference `# SPEC-I0N` in code. kiro-layer entries start at I08.
