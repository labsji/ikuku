# install-prospect.ps1 — Prospect mode: import preconfigured WSL dump
# Called by the installer when it detects a .tar file alongside the exe
# Usage: powershell -File install-prospect.ps1 -TarPath "C:\path\to\ikuku-wsl.tar"

param(
    [string]$TarPath = "",
    [string]$DistroName = "ikuku",
    [string]$InstallPath = "C:\ikuku"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== ikuku: Prospect Mode ===" -ForegroundColor Cyan
Write-Host "Importing preconfigured ERPNext..."

# Step 0: Find tar if not specified
if (-not $TarPath -or -not (Test-Path $TarPath)) {
    # Look for any .tar in the script directory, parent, or alongside the exe
    $searchDirs = @($scriptDir, (Split-Path $scriptDir), "$env:USERPROFILE\Downloads")
    foreach ($dir in $searchDirs) {
        $found = Get-ChildItem -Path $dir -Filter "*wsl*.tar" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $TarPath = $found.FullName; break }
    }
    if (-not $TarPath) {
        Write-Host "ERROR: No WSL tar file found." -ForegroundColor Red
        exit 1
    }
}
Write-Host "Tar: $TarPath ($('{0:N1} GB' -f ((Get-Item $TarPath).Length / 1GB)))"

# Step 1: Ensure WSL2 is available
$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }

if (-not $WSL) {
    Write-Host "Installing WSL..." -ForegroundColor Yellow
    # Try wsl --install (Windows 11 / Server 2022+)
    $wslInstall = Start-Process -FilePath "wsl.exe" -ArgumentList "--install","--no-distribution" -Wait -PassThru -NoNewWindow 2>$null
    # Check if MSI approach is needed
    if (-not (Test-Path "C:\Program Files\WSL\wsl.exe")) {
        $msiPath = Join-Path $scriptDir "wsl.msi"
        if (Test-Path $msiPath) {
            Write-Host "Installing WSL from MSI..."
            Start-Process msiexec.exe -ArgumentList "/i","$msiPath","/qn","/norestart" -Wait -NoNewWindow
        }
    }
    # Enable features if needed
    dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>$null | Out-Null
    dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>$null | Out-Null

    if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
    elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }

    if (-not $WSL) {
        Write-Host "WSL installation requires a reboot. Please restart and run ikuku again." -ForegroundColor Yellow
        Write-Host "After reboot, the tray app will continue the setup automatically."
        # Write state file so tray knows to resume
        @{ "state" = "pending_reboot"; "tar" = $TarPath } | ConvertTo-Json | Set-Content "$InstallPath\setup-state.json"
        exit 0
    }
}

Write-Host "WSL: $($WSL)" -ForegroundColor Green

# Step 2: Import the tar as a WSL distro
Write-Host "Importing WSL distro '$DistroName' (this takes 2-5 minutes)..."
if (-not (Test-Path $InstallPath)) { New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null }

# Check if distro already exists
$existing = & $WSL -l -q 2>&1 | Out-String
if ($existing -match $DistroName) {
    Write-Host "  Distro '$DistroName' already exists, unregistering..."
    & $WSL --unregister $DistroName 2>&1 | Out-Null
}

$importResult = & $WSL --import $DistroName $InstallPath $TarPath 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: WSL import failed: $importResult" -ForegroundColor Red
    Write-Host "This may require a reboot (VirtualMachinePlatform feature)."
    @{ "state" = "pending_reboot"; "tar" = $TarPath } | ConvertTo-Json | Set-Content "$InstallPath\setup-state.json"
    exit 1
}
Write-Host "  Import complete." -ForegroundColor Green

# Step 3: Start containers
Write-Host "Starting ERPNext..."
& $WSL -d $DistroName -u root -- bash -c "podman start ikuku_mariadb_1 ikuku_redis_1 ikuku_frappe_1 2>/dev/null || cd /opt/ikuku && podman-compose up -d 2>/dev/null"
Write-Host "  Containers starting..."

# Step 4: Set up port forwarding (WSL → localhost)
Write-Host "Setting up network access..."
$wslIp = (& $WSL -d $DistroName -u root -- hostname -I 2>$null).Trim().Split(' ')[0]
if ($wslIp) {
    netsh interface portproxy add v4tov4 listenport=8000 listenaddress=0.0.0.0 connectport=8000 connectaddress=$wslIp 2>&1 | Out-Null
}
netsh advfirewall firewall add rule name="ikuku" dir=in action=allow protocol=TCP localport=8000 2>&1 | Out-Null

# Step 5: Configure .wslconfig to prevent auto-shutdown
$wslConfig = "$env:USERPROFILE\.wslconfig"
@("[wsl2]", "vmIdleTimeout=-1") | Set-Content $wslConfig

# Step 6: Copy ikuku.conf to working directory
$confSource = Join-Path $scriptDir "ikuku.conf"
if (Test-Path $confSource) {
    Copy-Item $confSource "$InstallPath\ikuku.conf" -Force
}

# Step 7: Install tray app to startup
$trayExe = Join-Path $scriptDir "ikuku-tray.exe"
if (Test-Path $trayExe) {
    Copy-Item $trayExe "$InstallPath\ikuku-tray.exe" -Force
    # Register as startup
    $startupLink = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\ikuku-tray.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupLink)
    $shortcut.TargetPath = "$InstallPath\ikuku-tray.exe"
    $shortcut.WorkingDirectory = $InstallPath
    $shortcut.Save()
    # Launch now
    Start-Process -FilePath "$InstallPath\ikuku-tray.exe" -WorkingDirectory $InstallPath
}

# Step 8: Wait for ERPNext and open browser
Write-Host "Waiting for ERPNext to be ready..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 5
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:8000" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    if ($i % 6 -eq 5) { Write-Host "  Still starting ($([int](($i+1)*5))s)..." }
}

if ($ready) {
    Write-Host ""
    Write-Host "=== ERPNext is ready! ===" -ForegroundColor Green
    Write-Host "  URL:   http://localhost:8000"
    Write-Host "  Login: Administrator / admin"
    Write-Host ""
    Start-Process "http://localhost:8000"
} else {
    Write-Host ""
    Write-Host "ERPNext is still starting. The tray icon will show 'Ready' when it's available." -ForegroundColor Yellow
    Write-Host "  URL:   http://localhost:8000"
    Write-Host "  Login: Administrator / admin"
}

# Write success state
@{ "state" = "installed"; "distro" = $DistroName; "path" = $InstallPath } | ConvertTo-Json | Set-Content "$InstallPath\setup-state.json"
Write-Host ""
Write-Host "ikuku tray icon is in your system tray — that's your go-to for ERPNext." -ForegroundColor Cyan
