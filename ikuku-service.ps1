# ikuku-service.ps1 — Scheduled task entry point
# Starts containers, waits for ready, refreshes port proxy, keeps WSL alive
$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }
$IKUKU_DIR = "/opt/ikuku"

# Wait for WSL systemd
for ($i = 0; $i -lt 30; $i++) {
    $state = & $WSL -u root -- bash -c 'systemctl is-system-running 2>/dev/null || echo waiting'
    if ($state -match "running|degraded") { break }
    Start-Sleep 2
}

# Clean stale containers then start fresh
& $WSL -u root -- bash -c 'cd /opt/ikuku; podman-compose down 2>/dev/null; podman-compose up -d'

# Wait for HTTP 200
for ($i = 0; $i -lt 30; $i++) {
    $ok = & $WSL -u root -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:8000 2>/dev/null"
    if ($ok -eq "200") { break }
    Start-Sleep 2
}

# Refresh port proxy
& "$PSScriptRoot\update-portproxy.ps1"

# Keep WSL alive
& $WSL -u root -- sleep infinity
