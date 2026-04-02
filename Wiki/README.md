# Frappe Wiki — Windows Installer

One-click Windows installer for [Frappe Wiki](https://github.com/frappe/wiki) V3. A clean, open source wiki for documentation and knowledge bases — with change approval workflows and revision history built in.

## Quick Start

1. Download `frappe-wiki-lite.exe` from [Releases](../../releases)
2. Run the installer (needs admin rights + internet)
3. Open `http://wiki.localhost:8000/wiki/`

## Why Frappe Wiki?

The wiki market is crowded — MediaWiki, Confluence, BookStack, Outline, Notion... Evaluating each one means provisioning servers, configuring databases, fighting with Docker. ikuku lets you try Frappe Wiki in 5 minutes on your Windows machine.

### Social features out of the box

- **Change approval workflow** — edits go through review before publishing
- **Revision history** — full audit trail of every change
- **Markdown authoring** — clean writing experience with Ace editor
- **Full-text search** — powered by RedisSearch

## Access

- Local: `http://wiki.localhost:8000/wiki/`
- LAN: `http://<machine-name>:8000/wiki/`
- Admin login: `http://wiki.localhost:8000` → `Administrator` / `admin`

## Requirements

- Windows 10 (build 19041+), Windows 11, or Windows Server 2022
- Hardware virtualization enabled (for WSL2)
- 16 GB RAM recommended
- Admin rights for install

See the [root README](../README.md) for architecture details.
