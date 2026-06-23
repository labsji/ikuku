# ikuku — Specification & Style Guide

## Purpose

ikuku is a Windows installer that gives non-technical users a running ERPNext instance in under 10 minutes. This document defines the specs for the public version.

---

## Style

### Shell Scripts (init.sh)
- `set -e` or explicit error handling — never silent failures
- Echo progress to stdout (user watches the terminal)
- Idempotent: re-running a completed step skips it

### PowerShell Scripts (install.ps1, build-installer.ps1)
- `$ErrorActionPreference = "Stop"` — fail loudly
- Check prerequisites before acting (WSL2, podman)
- Report errors with actionable guidance ("Install WSL2: https://...")

### NSIS Installer (ikuku-installer.nsi)
- Whitelabel defines have defaults — installer works without `whitelabel.conf`
- No hardcoded paths beyond `$PROGRAMFILES64\ikuku`
- Uninstaller must be created even on partial install (so user can clean up)

### CI Workflows (.github/workflows/)
- Lite variant: zero AWS dependency (pulls only from public GitHub)
- Full variant: AWS only for container image bundle (large binary blobs)
- Release artifacts named clearly: `ikuku-lite.exe`, `ikuku-full.zip`

---

## QA Checklist (per commit to main)

### Automated:
- [ ] No secrets in source (`grep -r "AKIA\|sk-\|Admin@2026"`)
- [ ] No references to private branches or CodeCommit
- [ ] NSIS compiles without error (CI build job)
- [ ] GitHub Actions lint (valid YAML)

### Manual (before release tag):
- [ ] Fresh Windows 10/11 — installer runs end-to-end
- [ ] ERPNext accessible at `localhost:8000` after install
- [ ] Login works: Administrator / admin
- [ ] `/app/bind-agent` loads (bind installed)
- [ ] Uninstall removes containers and data
- [ ] Reboot → auto-start works

---

## Spec Entries

### SPEC-I01: Single Site, Single Port
**Behavior:** ikuku creates one ERPNext site on port 8000. No multi-site complexity.  
**Implementation:** `init.sh` → `SITE="ikuku.localhost"`, `docker-compose.yml` → port 8000 only.  
**Test:** After install, `localhost:8000` responds. No port 8001.

### SPEC-I02: ERPNext as Default App
**Behavior:** ERPNext is installed by default without user configuration.  
**Implementation:** `init.sh` → `APPS="${IKUKU_APPS:-erpnext}"`.  
**Test:** Fresh install → ERPNext modules available in desk.

### SPEC-I03: Whitelabel as Optional Overlay
**Behavior:** Without `whitelabel.conf`, installer builds as "ikuku". With it, uses reseller branding.  
**Implementation:** `build-installer.ps1` reads conf if present, passes `/D` defines to NSIS. NSIS has defaults.  
**Test:** Build without conf → `ikuku-lite.exe`. Build with conf → `acme-erpnext-lite.exe`.

### SPEC-I04: bind Agent Bundled
**Behavior:** bind is installed as a Frappe app on first boot. Agent page available at `/app/bind-agent`.  
**Implementation:** `init.sh` → installs from `shared/bind.tar.gz` if present.  
**Test:** After boot, navigate to `/app/bind-agent` → agent UI loads.

### SPEC-I05: Open-Source LLM Default
**Behavior:** bind uses Ollama (local, open-source) as default LLM. No cloud dependency.  
**Implementation:** `init.sh` → sets `bind_llm.provider = "ollama"` in site_config.  
**Test:** With Ollama running, agent responds to natural language input.

### SPEC-I06: Kiro as Opt-In Layer
**Behavior:** Kiro CLI is available on the `kiro-layer` branch only. Main branch has no Kiro dependency.  
**Implementation:** `kiro-layer` branch adds Kiro CLI to `shared/`, sets `bind_llm.provider = "kiro"`.  
**Test:** Main branch builds without Kiro. Kiro-layer branch includes kiro-cli binary.

### SPEC-I07: Idempotent Init
**Behavior:** Running init.sh on an already-initialized bench skips setup and starts services.  
**Implementation:** `init.sh` → checks for `frappe-bench/apps/frappe`, skips if present.  
**Test:** Run init twice → second run says "Bench already exists" and starts bench.

---

## Adding New Specs

1. Name: `SPEC-INn: Title` (I = ikuku, N = number)
2. Define: **Behavior** (what the user observes), **Implementation** (where in code), **Test** (how to verify)
3. Reference in code: `# SPEC-I0N`
4. Update this file
