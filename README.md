# ikuku 🌬️

Frappe apps on Windows — a better experience than Linux.

> *ikuku* (Igbo: breeze) — open Windows and let the breeze in.

Each Frappe app gets a Windows installer that takes you from zero to running in minutes. No Docker Desktop, no Linux VM, no manual setup. Goes beyond evaluation — stops just short of production.

## Apps

| App | Status | Installer |
|-----|--------|-----------|
| [Frappe LMS](lms/) | ✅ Tested | `frappe-lms-lite.exe` |
| [Frappe ERPNext](erpnext/) | 🔧 Scaffolded | `frappe-erpnext-lite.exe` |
| [Frappe Wiki](Wiki/) | 🔧 Scaffolded | `frappe-wiki-lite.exe` |
| Frappe CRM | 🔜 Planned | `frappe-crm-lite.exe` |
| Frappe Helpdesk | 🔜 Planned | `frappe-helpdesk-lite.exe` |

## How it works

Every installer uses the same stack:
- **WSL2 Ubuntu** — real Linux inside Windows
- **Podman** — Docker-compatible, no Docker Desktop license
- **Scheduled task (S4U)** — survives reboot, no stored passwords
- **Port proxy** — LAN accessible from any machine

```
┌─────────────────────────────────────────┐
│  Windows 10/11 or Server 2022           │
│  ┌─────────────────────────────────┐    │
│  │  WSL2 Ubuntu + Podman           │    │
│  │  ┌───────────────────────┐      │    │
│  │  │  Frappe App (:8000)   │      │    │
│  │  │  MariaDB · Redis      │      │    │
│  │  └───────────────────────┘      │    │
│  └─────────────────────────────────┘    │
│  Scheduled task (auto-start on boot)    │
│  Port proxy: LAN:port → WSL:8000       │
└─────────────────────────────────────────┘
```

## Beyond evaluation

ikuku doesn't stop at "can I see it running":
- **Sample data** — pre-loaded content so the app isn't empty
- **Backup/restore** — protect your evaluation work
- **Update scripts** — stay current with upstream
- **Windows-native touches** — Start Menu, system tray, notifications

## Community

ikuku is a distribution channel for Frappe apps, not a fork. We depend on and contribute to the [Frappe ecosystem](https://github.com/frappe).

## Requirements

- Windows 10 (build 19041+), Windows 11, or Windows Server 2022
- Hardware virtualization enabled (for WSL2)
- 16 GB RAM recommended
- Admin rights for install

