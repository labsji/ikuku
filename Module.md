# Module: ikuku

## Purpose

Cross-platform ERPNext installer. Download → double-click → ERPNext running. The entry point for prospects, the trust-builder for the ecosystem.

## Target Audience

Non-technical business owners evaluating ERPNext. Zero terminal knowledge assumed.

## What's Inside

| Component | What It Does |
|-----------|-------------|
| Windows NSIS installer | One-click install on Windows 10/11 |
| Linux install.sh | `curl \| bash` for Linux/Mac |
| Two-site architecture | Demo (port 8000, sample data) + MVP (port 8001, blank) |
| seed.repl support | Pre-configure MVP from reseller's agent session |
| Whitelabel (private branch) | Reseller branding on installer, login, reports |
| Progress UI | Visual feedback during first-boot container setup |
| Auto-start service | Survives reboot, runs as background service |

## Design Principle

The prospect's experience: download → run → see ERPNext → start evaluating. Under 10 minutes. No cloud account, no terminal, no Docker knowledge visible.

## Relationship to Other Modules

- **next-sale** trains resellers who distribute ikuku to prospects
- **bind** provides the agent that runs inside ikuku (on MVP site)
- **next-cloud** is the next step after local evaluation (deploy to VPC)
- **next-engage** uses ikuku as substrate for student projects (e.g., code signing tutorial)

## Whole-Theme Files

- `Whole-Reseller-Pipeline.md` — How ikuku is the reseller's distribution tool
- `Whole-Student-SkillShowcase.md` — How signing/packaging ikuku is a student project
- `Whole-BizOwner-Freedom.md` — How local install = data sovereignty from day one
