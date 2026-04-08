# shared/wsl-setup.ps1 — Common WSL2 + podman setup for all Frappe apps
param([string]$MemoryGB = "12", [string]$SwapGB = "4")

$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }

# WSL memory config
@("[wsl2]","memory=${MemoryGB}GB","swap=${SwapGB}GB") | Set-Content "$env:USERPROFILE\.wslconfig"

# Ensure Ubuntu
$distros = & $WSL -l -q 2>&1 | Out-String
if ($distros -notmatch "Ubuntu") {
    Write-Host "Installing Ubuntu..."
    & $WSL --install Ubuntu --no-launch
    $ubuntuExe = (Get-AppxPackage *Ubuntu*).InstallLocation + "\ubuntu.exe"
    if (Test-Path $ubuntuExe) { & $ubuntuExe install --root }
}

# Ensure podman
$podmanCheck = & $WSL -u root -- which podman 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing podman..."
    & $WSL -u root -- bash -c "apt-get update && apt-get install -y podman podman-compose > /dev/null 2>&1 && sed -i '/^unqualified-search-registries/d' /etc/containers/registries.conf && echo 'unqualified-search-registries = [\"docker.io\"]' >> /etc/containers/registries.conf"
}
