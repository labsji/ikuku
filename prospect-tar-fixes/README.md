# Prospect WSL-tar fixes (2026-09-14)

These files are the corrected versions that must live inside the exported prospect
`ikuku-wsl.tar` (under `/opt/ikuku` and `/etc`) so a prospect import comes up rapidly
with ERPNext serving. They were verified live: ERPNext returned HTTP 200 on
localhost:8000 in ~30s from the pre-built bench (no rebuild).

- **init.sh** — start-only container entrypoint (`command: bash /workspace/init.sh`).
  Points bench at the `mariadb`/`redis` compose service names, waits for them, sets the
  current site, then `bench start`. Deliberately has **no rebuild path** (rebuild would
  cost ~30 min and defeats the pre-built-tar rapid-install model).

- **boot.sh** — brings the container stack up via `podman-compose up -d`. This is critical:
  starting containers individually with `podman start` loses the compose pod network, so
  `redis`/`mariadb` DNS names don't resolve and socketio dies (EAI_AGAIN). Compose restores
  the network + `--network-alias`.

- **wsl.conf** — install to `/etc/wsl.conf`. The `[boot] command=/opt/ikuku/boot.sh` line
  makes the stack auto-start on every WSL distro boot (no Windows scheduled task needed for
  container startup).

## Still TODO before these are "done"
- **Keepalive**: the WSL distro terminates when no session holds it open, stopping the
  containers. `install.ps1`'s prospect block must register a Windows-side keepalive
  (a scheduled task running `wsl -d ikuku -u root -- sleep infinity`) and the `ikuku`
  service task — currently the prospect block `return`s before that step.
- **Kiro-cli auth**: the S3 `kiro-cli` (2.15.0, stock Amazon Q CLI) does NOT accept the
  auth-proxy `kiro_api_key` (login only supports Identity Center / Builder ID / device flow).
  The repo scripts assume a custom kiro-cli build that reads `KIRO_API_KEY`. Resolve by
  either shipping that custom build, pre-baking a logged-in kiro session into the tar, or
  accepting a one-time device login on first "Talk to Kiro".
- Fold init.sh/boot.sh/wsl.conf into the `create-dump.sh` / `build-evalkit-niche.sh`
  pipeline so future tars are built correct from the start.
