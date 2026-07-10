# stop.ps1 — Stop ikuku
$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }
schtasks /end /tn "ikuku" 2>$null
& $WSL -u root -- bash -c "cd /opt/ikuku; podman-compose down" 2>$null

$Port = "8000"
$confFile = "$PSScriptRoot\ikuku.conf"
if (Test-Path $confFile) {
    $line = Get-Content $confFile | Where-Object { $_ -match "^LMS_PORT=" }
    if ($line) { $Port = ($line -split '=', 2)[1].Trim() }
}
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>$null
Write-Host "ikuku stopped."
