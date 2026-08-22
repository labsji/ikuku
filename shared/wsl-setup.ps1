# shared/wsl-setup.ps1 - Common WSL2 + podman setup for all Frappe apps
param([string]$MemoryGB = "12", [string]$SwapGB = "4", [switch]$SkipDistro)

$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = (Get-Command wsl.exe).Source }

if (-not $WSL) {
    Write-Host "WSL not found. Installing WSL..."
    wsl --install --no-distribution 2>$null
    Start-Sleep 10
    if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
    elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = (Get-Command wsl.exe).Source }
    if (-not $WSL) { Write-Error "WSL installation failed. Reboot and retry."; exit 1 }
}

# WSL memory config
@("[wsl2]","memory=${MemoryGB}GB","swap=${SwapGB}GB") | Set-Content "$env:USERPROFILE\.wslconfig"

# Ensure WSL2 is the default (critical for multi-user scenarios)
& $WSL --set-default-version 2 2>$null

# In prospect mode (SkipDistro), we only need the WSL kernel — no Ubuntu distro
if ($SkipDistro) {
    Write-Host "WSL2 kernel ready (prospect mode — distro will be imported from tar)"
    return
}

# Ensure Ubuntu distro exists
$distros = & $WSL -l -q 2>&1 | Out-String
if ($distros -notmatch "Ubuntu") {
    Write-Host "Installing Ubuntu..."

    # Method 1: Try wsl --install (works on Win10/11 with Store access)
    $installResult = & $WSL --install -d Ubuntu --no-launch 2>&1 | Out-String
    Start-Sleep 5
    $distros = & $WSL -l -q 2>&1 | Out-String

    # Method 2: If --install failed, use rootfs import (works on Server)
    if ($distros -notmatch "Ubuntu") {
        Write-Host "Store install failed. Using rootfs import..."
        # Ensure WSL2 kernel is installed (required before import can work)
        Write-Host "  Ensuring WSL2 kernel is present..."
        & $WSL --update 2>$null
        $rootfs = "$env:TEMP\ubuntu-rootfs.tar.gz"
        # Check bundled locations first (no download needed)
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $bundledPaths = @(
            (Join-Path $scriptDir "ubuntu-rootfs.tar.gz"),
            "C:\Users\Public\ubuntu-rootfs.tar.gz",
            (Join-Path $scriptDir "..\shared\ubuntu-rootfs.tar.gz")
        )
        foreach ($p in $bundledPaths) {
            if (Test-Path $p) { $rootfs = $p; Write-Host "  Using bundled rootfs: $p"; break }
        }
        if (!(Test-Path $rootfs)) {
            Write-Host "  Downloading Ubuntu rootfs..."
            curl.exe -sL -o $rootfs "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz"
        }
        if (Test-Path $rootfs) {
            $wslDir = "C:\WSL\Ubuntu"
            New-Item -ItemType Directory -Path $wslDir -Force | Out-Null
            & $WSL --import Ubuntu $wslDir $rootfs
            & $WSL --set-default Ubuntu
            Write-Host "  Ubuntu imported via rootfs."
        } else {
            Write-Host "  ERROR: Could not download Ubuntu rootfs."
        }
    }
}

# Ensure podman
$podmanCheck = & $WSL -u root -- which podman 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing podman..."
    & $WSL -u root -- bash -c "apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman podman-compose curl git hostname > /dev/null 2>&1; sed -i '/^unqualified-search-registries/d' /etc/containers/registries.conf; printf 'unqualified-search-registries = [\`"docker.io\`"]\n' >> /etc/containers/registries.conf; echo PODMAN_OK"
}
