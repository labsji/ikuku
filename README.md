# ikuku 🌬️

ERPNext on Windows — one installer, one click.

> *ikuku* (Igbo: breeze) — open Windows and let the breeze in.

## Quick Start

1. Download `ikuku-lite.exe` from [Releases](../../releases)
2. Run the installer
3. Open `http://localhost:8000`
4. Login: `Administrator` / `admin`

ERPNext is pre-selected. First boot takes a few minutes (pulls containers, creates bench).

## What You Get

| Component | Details |
|-----------|---------|
| ERPNext | Full ERP — accounting, inventory, HR, CRM |
| Single site | `http://localhost:8000` — your business, your data |
| Survives reboot | Runs as background service |
| Clean uninstall | Removes containers + data |

## White-Label (for resellers)

Brand the installer with your company name:

1. Copy `whitelabel.conf.example` → `whitelabel.conf`
2. Edit: company name, title, exe name, logo
3. Run: `powershell build-installer.ps1`
4. Distribute: `your-brand-lite.exe`

See `whitelabel.conf.example` for all options.

## How It Works

- WSL2 + podman (auto-configured by installer)
- Docker Compose: MariaDB + Redis + Frappe bench
- Single port (8000), single site, no Docker Desktop needed

## Requirements

- Windows 10/11 (64-bit)
- 8GB RAM minimum
- WSL2 capable (most modern machines)

## Code Signing

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

## Apps

Default: ERPNext. Override with environment variable:

```
IKUKU_APPS=wiki,erpnext,crm
```

## Privacy

This program runs entirely on your local machine. No data is sent externally. The bundled Frappe applications may check for updates — see [Frappe privacy policy](https://frappecloud.com/privacy).

## License

GPL-3.0 — any distribution of modified versions must include source code.
