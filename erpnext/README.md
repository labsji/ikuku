# Frappe ERPNext — Windows Installer

One-click Windows installer for [Frappe ERPNext](https://github.com/frappe/erpnext). Runs the full stack (MariaDB, Redis, Frappe) inside WSL2 + podman — no Docker Desktop, no Linux VM, no manual setup.

## Quick Start

1. Download `frappe-erpnext-lite.exe` from [Releases](../../releases)
2. Run the installer (needs admin rights + internet)
3. Open `http://erp.localhost:8000/app`

## Access

- Local: `http://erp.localhost:8000/app`
- LAN: `http://<machine-name>:8000/app`
- Admin: username `Administrator`, password `admin`

## Requirements

- Windows 10 (build 19041+), Windows 11, or Windows Server 2022
- Hardware virtualization enabled (for WSL2)
- 16 GB RAM recommended
- Admin rights for install

See the [root README](../README.md) for architecture details.
