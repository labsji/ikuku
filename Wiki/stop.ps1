# stop.ps1 - Stop Frappe Wiki
$WSL = "wsl.exe"
$LMS_DIR = "/opt/frappe-wiki"

schtasks /end /tn "FrappeWiki" 2>$null
& $WSL -u root -- bash -c "cd $LMS_DIR && podman-compose down" 2>$null

# Read port from config
$Port = "8000"
$confFile = "$PSScriptRoot\wiki.conf"
if (Test-Path $confFile) {
    $line = Get-Content $confFile | Where-Object { $_ -match "^LMS_PORT=" }
    if ($line) { $Port = ($line -split '=', 2)[1].Trim() }
}
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>$null
Write-Host "Frappe Wiki stopped."
