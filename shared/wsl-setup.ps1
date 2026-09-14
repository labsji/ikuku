# shared/wsl-setup.ps1 - Common WSL2 + podman setup for all Frappe apps
param([string]$MemoryGB = "12", [string]$SwapGB = "4", [switch]$SkipDistro)

# Native commands here (wsl.exe, dism.exe) legitimately write to stderr and return
# non-zero exit codes (e.g. "reboot required"). If a caller set ErrorActionPreference
# to 'Stop', that stderr becomes a terminating NativeCommandError and kills this script
# mid-run. Force 'Continue' so we control the flow ourselves via explicit checks.
$ErrorActionPreference = "Continue"

# On a pristine Windows 11, C:\Windows\System32\wsl.exe is an INBOX STUB that only
# knows how to bootstrap `wsl --install`. The real WSL2 (with a working --import) is
# the Store/MSI package installed at C:\Program Files\WSL\wsl.exe. We must detect the
# stub-only state and actually install real WSL2 - checking `Get-Command wsl.exe` is
# NOT sufficient because the stub always satisfies it.
$realWslPath = "C:\Program Files\WSL\wsl.exe"
$WSL = $null
if (Test-Path $realWslPath) { $WSL = $realWslPath }

if (-not $WSL) {
    Write-Host "Real WSL2 not found (only inbox stub present). Installing WSL2..."
    # Ensure the underlying Windows features are enabled first - required before the
    # WSL2 package can function. These may require a reboot on a fresh machine.
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>&1 | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>&1 | Out-Null

    # Install the WSL2 package (kernel + real wsl.exe) without any distro.
    # Use the inbox stub explicitly to bootstrap the real package.
    & "$env:SystemRoot\System32\wsl.exe" --install --no-distribution 2>&1 | Out-Null
    Start-Sleep 15
    # Also try updating to pull the latest kernel if the package landed.
    & "$env:SystemRoot\System32\wsl.exe" --update 2>&1 | Out-Null
    Start-Sleep 5

    if (Test-Path $realWslPath) {
        $WSL = $realWslPath
    } else {
        # Real WSL2 still not present - the VirtualMachinePlatform feature almost
        # certainly needs a reboot to activate. Return WITHOUT exiting so the caller
        # (install.ps1) can detect the missing binary and drive the reboot/resume
        # flow. Do NOT call 'exit' here: this script is invoked with '&', and 'exit'
        # would terminate the parent install.ps1 too, skipping its reboot handling.
        Write-Host "WSL2 requires a reboot to finish installing (VirtualMachinePlatform)."
        return
    }
}

# WSL memory config
@("[wsl2]","memory=${MemoryGB}GB","swap=${SwapGB}GB") | Set-Content "$env:USERPROFILE\.wslconfig"

# Ensure WSL2 is the default (critical for multi-user scenarios)
& $WSL --set-default-version 2 2>$null

# In prospect mode (SkipDistro), we only need the WSL kernel - no Ubuntu distro
if ($SkipDistro) {
    Write-Host "WSL2 kernel ready (prospect mode - distro will be imported from tar)"
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
