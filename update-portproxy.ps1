# update-portproxy.ps1 — Refresh port forwarding (WSL IP changes on reboot)
param([string]$Port = "8000")

$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }
$confFile = "$PSScriptRoot\ikuku.conf"
if ($Port -eq "8000" -and (Test-Path $confFile)) {
    $line = Get-Content $confFile | Where-Object { $_ -match "^LMS_PORT=" }
    if ($line) { $Port = ($line -split '=', 2)[1].Trim() }
}

$wslIp = ((& $WSL -u root -- hostname -I).Trim() -split '\s+')[0]
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>$null
netsh interface portproxy add v4tov4 listenport=$Port listenaddress=0.0.0.0 connectport=8000 connectaddress=$wslIp
Write-Host "Port proxy: 0.0.0.0:$Port -> WSL($wslIp):8000"
