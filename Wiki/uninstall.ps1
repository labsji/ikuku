# uninstall.ps1 - Remove Frappe Wiki
$WSL = "wsl.exe"
$LMS_DIR = "/opt/frappe-wiki"

# Read port from config
$Port = "8000"
$confFile = "$PSScriptRoot\wiki.conf"
if (Test-Path $confFile) {
    $line = Get-Content $confFile | Where-Object { $_ -match "^LMS_PORT=" }
    if ($line) { $Port = ($line -split '=', 2)[1].Trim() }
}

Write-Host "Removing scheduled task..."
schtasks /end /tn "FrappeWiki" 2>$null
schtasks /delete /tn "FrappeWiki" /f 2>$null

Write-Host "Stopping containers..."
& $WSL -u root -- bash -c "cd $LMS_DIR && podman-compose down -v 2>/dev/null"

Write-Host "Removing port proxy and firewall rule..."
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>$null
netsh advfirewall firewall delete rule name="Frappe-Wiki" 2>$null

Write-Host "Cleaning up WSL files..."
& $WSL -u root -- rm -rf $LMS_DIR

Write-Host "Frappe Wiki uninstalled." -ForegroundColor Yellow
