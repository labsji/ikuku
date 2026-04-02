# uninstall.ps1 — Remove ikuku
$WSL = "wsl.exe"

$Port = "8000"
$confFile = "$PSScriptRoot\ikuku.conf"
if (Test-Path $confFile) {
    $line = Get-Content $confFile | Where-Object { $_ -match "^LMS_PORT=" }
    if ($line) { $Port = ($line -split '=', 2)[1].Trim() }
}

Write-Host "Removing scheduled task..."
schtasks /end /tn "ikuku" 2>$null
schtasks /delete /tn "ikuku" /f 2>$null

Write-Host "Stopping containers..."
& $WSL -u root -- bash -c "cd /opt/ikuku && podman-compose down -v 2>/dev/null"

Write-Host "Removing port proxy and firewall rule..."
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>$null
netsh advfirewall firewall delete rule name="ikuku" 2>$null

Write-Host "Cleaning up WSL files..."
& $WSL -u root -- rm -rf /opt/ikuku

Write-Host "ikuku uninstalled." -ForegroundColor Yellow
