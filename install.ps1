# install.ps1 - ikuku: install Frappe apps on Windows
# Usage: powershell -File install.ps1 -Apps "wiki,lms"
param([string]$Apps = "wiki")

$ErrorActionPreference = "Stop"
$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }
$IKUKU_DIR = "/opt/ikuku"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sharedDir = Join-Path $scriptDir "shared"
if (!(Test-Path $sharedDir)) { $sharedDir = Join-Path $scriptDir "..\shared" }

# Read config
$conf = @{ LMS_PORT="8000" }
$confFile = Join-Path $scriptDir "ikuku.conf"
if (Test-Path $confFile) {
    Get-Content $confFile | ForEach-Object {
        $k, $v = $_ -split '=', 2
        if ($k -and $v) { $conf[$k.Trim()] = $v.Trim() }
    }
}

Write-Host "=== ikuku: Installing Frappe apps ===" -ForegroundColor Cyan
# Signal tray app: installing
New-Item -ItemType Directory -Path "C:\ikuku" -Force | Out-Null
Set-Content -Path "C:\ikuku\status.txt" -Value "installing"

# Start tray app immediately (first thing user sees)
$trayExe = "C:\ikuku\ikuku-tray.exe"
Stop-Process -Name "ikuku-tray" -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
if (Test-Path "$scriptDir\ikuku-tray.exe") {
    Copy-Item "$scriptDir\ikuku-tray.exe" $trayExe -Force
}
if (Test-Path $trayExe) {
    Start-Process $trayExe
    # Register auto-start on login
    reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v ikuku /t REG_SZ /d $trayExe /f 2>$null
}

Write-Host "Apps: $Apps | Port: $($conf.LMS_PORT)"

# Step 0: Check WSL2 + container support
$errors = @()
if (-not $WSL) {
    # WSL binary not found at all - unusual, check if Windows version supports it
    $build = [System.Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        $errors += "This Windows version does not support WSL2 (requires build 19041+)."
    }
    # Otherwise wsl-setup.ps1 will handle installation
} else {
# Basic WSL check - only fail on hardware issues, not "not installed" state
$wslCheck = & $WSL --status 2>&1 | Out-String
if ($wslCheck -match "not supported") {
    $errors += "WSL2 is not available on this system (hardware virtualization may be disabled)."
}
# Check if any distro is running WSL1 (only matters if distros exist)
$wslVersion = & $WSL -l -v 2>&1 | Out-String
if ($wslVersion -match "VERSION\s+1" -and $wslVersion -notmatch "VERSION\s+2" -and $wslVersion -notmatch "no installed") {
    $errors += "WSL is running in version 1 mode. WSL2 required."
}
# Smoke-test: can podman actually create containers with networking?
# Only test if podman is already installed (skip on fresh install - wsl-setup.ps1 handles it)
if ($errors.Count -eq 0) {
    $hasPodman = & $WSL -u root -- which podman 2>&1 | Out-String
    if ($hasPodman -match "/podman") {
        $nsTest = & $WSL -u root -- bash -c "podman run --rm alpine echo ok 2>&1" | Out-String
        if ($nsTest -notmatch "ok") {
            $errors += "Podman cannot start containers on this system.`n`nThis usually means the WSL2 kernel lacks full namespace support`n(e.g. EC2/cloud VMs without nested virtualization).`n`nDetails: $($nsTest.Trim())"
        }
    }
}
} # end WSL found
if ($errors.Count -gt 0) {
    $msg = "ikuku cannot install:`n`n" + ($errors -join "`n") + "`n`nRequirements:`n- Windows 10/11 or Server 2019+`n- Hardware virtualization (nested virt for VMs)`n- WSL2 with a real Linux kernel`n`nFiles have been extracted to: $scriptDir"
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($msg, "ikuku - Installation Failed", "OK", "Error") | Out-Null
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════
# PROSPECT MODE DETECTION
# If a complete WSL filesystem tar exists alongside the installer,
# import it directly. This is the fastest path — everything is pre-built.
# The tar contains: Ubuntu + podman + images + volumes + ERPNext + niche data.
# Created by: delegate runs evalkit build, exports WSL filesystem.
# ═══════════════════════════════════════════════════════════════════════
$wslTar = Get-ChildItem -Path $scriptDir, (Split-Path $scriptDir), "$env:USERPROFILE\Downloads" -Filter "*wsl*.tar" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wslTar) {
    Write-Host ""
    Write-Host "=== Prospect Mode: Importing preconfigured ERPNext ===" -ForegroundColor Green
    Write-Host "Found: $($wslTar.Name) ($([math]::Round($wslTar.Length / 1GB, 1)) GB)"
    Set-Content -Path "C:\ikuku\status.txt" -Value "importing"

    # Ensure WSL2 kernel is installed (just the kernel, no distro needed)
    & "$sharedDir\wsl-setup.ps1" -MemoryGB 12 -SwapGB 4 -SkipDistro

    # Prevent WSL auto-shutdown
    @("[wsl2]", "vmIdleTimeout=-1", "memory=12GB", "swap=4GB") | Set-Content "$env:USERPROFILE\.wslconfig"

    # Import the filesystem as 'ikuku' distro
    $distroName = "ikuku"
    $installPath = "C:\ikuku"
    Write-Host "Importing WSL distro '$distroName' (2-5 minutes)..."
    $existing = & $WSL -l -q 2>&1 | Out-String
    if ($existing -match $distroName) {
        Write-Host "  Replacing existing '$distroName' distro..."
        & $WSL --unregister $distroName 2>&1 | Out-Null
    }
    & $WSL --import $distroName $installPath $wslTar.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WSL import failed. A reboot may be required (VirtualMachinePlatform feature)." -ForegroundColor Yellow
        Write-Host "After reboot, run this installer again — it will resume." -ForegroundColor Yellow
        Set-Content -Path "C:\ikuku\status.txt" -Value "pending_reboot"
        # Enable features that need reboot
        dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>$null | Out-Null
        dism /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>$null | Out-Null
        exit 0
    }
    Write-Host "  Import complete." -ForegroundColor Green

    # Start containers
    Write-Host "Starting ERPNext..."
    Set-Content -Path "C:\ikuku\status.txt" -Value "starting"
    & $WSL -d $distroName -u root -- bash -c "podman start ikuku_mariadb_1 ikuku_redis_1 ikuku_frappe_1 2>/dev/null || (cd /opt/ikuku && podman-compose up -d 2>/dev/null)"

    # Port forwarding
    $wslIp = (& $WSL -d $distroName -u root -- hostname -I 2>$null).Trim().Split(' ')[0]
    if ($wslIp) {
        netsh interface portproxy add v4tov4 listenport=8000 listenaddress=0.0.0.0 connectport=8000 connectaddress=$wslIp 2>&1 | Out-Null
    }
    netsh advfirewall firewall add rule name="ikuku" dir=in action=allow protocol=TCP localport=8000 2>&1 | Out-Null

    # Copy ikuku.conf to working directory
    $confSource = Join-Path $scriptDir "ikuku.conf"
    if (Test-Path $confSource) { Copy-Item $confSource "C:\ikuku\ikuku.conf" -Force }

    # Kiro CLI activation check
    $kiroActive = & $WSL -d $distroName -u root -- bash -c "test -f /opt/ikuku/shared/kiro-cli && /opt/ikuku/shared/kiro-cli --version 2>/dev/null && echo KIRO_OK" 2>$null
    if ($kiroActive -match "KIRO_OK") {
        Write-Host "  Kiro CLI: available (Master of Ceremonies ready)" -ForegroundColor Cyan
    }

    # Signal tray: ready
    Set-Content -Path "C:\ikuku\status.txt" -Value "active"
    Write-Host ""
    Write-Host "=== ERPNext is starting ===" -ForegroundColor Green
    Write-Host "  The tray icon will show Ready when ERPNext is available."
    Write-Host "  URL:   http://localhost:8000"
    Write-Host "  Login: Administrator / admin"
    Write-Host ""

    # Done — skip entire reseller build flow
    return
}
# ═══════════════════════════════════════════════════════════════════════
# RESELLER MODE: Build from scratch (existing behavior)
# ═══════════════════════════════════════════════════════════════════════

# Step 1: WSL2 + Ubuntu + Podman
Write-Host "Setting up WSL2 + Podman..."
$bundleDir = Join-Path $scriptDir "bundle"
$hasBundle = Test-Path "$bundleDir\img-mariadb.tar"

# WSL2 + Ubuntu + Podman (shared for both lite and full)
& "$sharedDir\wsl-setup.ps1" -MemoryGB 12 -SwapGB 4

# Load bundled container images if available (full/offline)
if ($hasBundle) {
    Write-Host "Loading container images (offline)..."
    $wslBundle = (& $WSL -u root -- wslpath -a ($bundleDir -replace '\\','/')).Trim()
    & $WSL -u root -- bash -c "ln -sf '$wslBundle' /tmp/ikuku-bundle; podman load -i /tmp/ikuku-bundle/img-mariadb.tar; podman load -i /tmp/ikuku-bundle/img-redis.tar; cat /tmp/ikuku-bundle/img-bench.tar.part* | podman load; podman tag ikuku-bench:fresh docker.io/frappe/bench:latest"
}

# Step 2a: Restore volume dumps if available (full variant — skip source build)
if ($hasBundle) {
    $hasDumps = (Test-Path "$bundleDir\bench-dump.tar.zst") -or (Test-Path "$bundleDir\bench-dump.tar.gz")
    if ($hasDumps) {
        Write-Host "Restoring preconfigured volumes from dump..."
        $wslBundle = (& $WSL -u root -- wslpath -a ($bundleDir -replace '\\','/')).Trim()

        # Create named volumes
        & $WSL -u root -- bash -c "podman volume create ikuku_mariadb-data 2>/dev/null; podman volume create ikuku_frappe-bench 2>/dev/null"

        # Determine dump format (zstd preferred, gzip fallback)
        if (Test-Path "$bundleDir\bench-dump.tar.zst") {
            & $WSL -u root -- bash -c "zstd -dc '$wslBundle/bench-dump.tar.zst' | podman volume import ikuku_frappe-bench -"
            & $WSL -u root -- bash -c "zstd -dc '$wslBundle/mariadb-dump.tar.zst' | podman volume import ikuku_mariadb-data -"
        } else {
            & $WSL -u root -- bash -c "gunzip -c '$wslBundle/bench-dump.tar.gz' | podman volume import ikuku_frappe-bench -"
            & $WSL -u root -- bash -c "gunzip -c '$wslBundle/mariadb-dump.tar.gz' | podman volume import ikuku_mariadb-data -"
        }
        Write-Host "  Volumes restored." -ForegroundColor Green
    }
}

# Step 2b: Copy docker config into WSL with selected apps
Write-Host "Setting up Frappe in WSL..."
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR"
$wslScript = (& $WSL -u root -- wslpath -a ($scriptDir -replace '\\','/')).Trim()
& $WSL -u root -- bash -c "cp '$wslScript/docker-compose.yml' '$wslScript/init.sh' $IKUKU_DIR/; tr -d '\r' < $IKUKU_DIR/init.sh > $IKUKU_DIR/init.sh.tmp; mv $IKUKU_DIR/init.sh.tmp $IKUKU_DIR/init.sh"
# Copy shared/ (kiro-cli, bind.tar.gz, next-sale.bundle) - self-contained, no runtime downloads
$wslShared = (& $WSL -u root -- wslpath -a ($sharedDir -replace '\\','/')).Trim()
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR/shared; cp '$wslShared/kiro-cli' '$wslShared/kiro-cli-chat' '$wslShared/bind.tar.gz' $IKUKU_DIR/shared/ 2>/dev/null; if [ -f '$wslShared/next-sale.bundle' ]; then cp '$wslShared/next-sale.bundle' $IKUKU_DIR/shared/; fi"
# Copy ikuku.conf if present (contains activation code baked by evalKit)
& $WSL -u root -- bash -c "if [ -f '$wslScript/ikuku.conf' ]; then cp '$wslScript/ikuku.conf' $IKUKU_DIR/; tr -d '\r' < $IKUKU_DIR/ikuku.conf > $IKUKU_DIR/ikuku.conf.tmp 2>/dev/null; mv $IKUKU_DIR/ikuku.conf.tmp $IKUKU_DIR/ikuku.conf 2>/dev/null; fi"
# Copy seed.repl and niche-context.md if present (pre-configured niche from evalKit)
& $WSL -u root -- bash -c "if [ -f '$wslScript/seed.repl' ]; then cp '$wslScript/seed.repl' $IKUKU_DIR/; tr -d '\r' < $IKUKU_DIR/seed.repl > $IKUKU_DIR/seed.repl.tmp 2>/dev/null; mv $IKUKU_DIR/seed.repl.tmp $IKUKU_DIR/seed.repl 2>/dev/null; fi"
& $WSL -u root -- bash -c "if [ -f '$wslScript/niche-context.md' ]; then cp '$wslScript/niche-context.md' $IKUKU_DIR/; tr -d '\r' < $IKUKU_DIR/niche-context.md > $IKUKU_DIR/niche-context.md.tmp 2>/dev/null; mv $IKUKU_DIR/niche-context.md.tmp $IKUKU_DIR/niche-context.md 2>/dev/null; fi"
# Write selected apps into .env for docker-compose
& $WSL -u root -- bash -c "echo 'IKUKU_APPS=$Apps' > $IKUKU_DIR/.env"

# Pre-create .ikuku directory with write permissions for frappe user (UID 1000)
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR/.ikuku; chmod 777 $IKUKU_DIR/.ikuku"

# Copy autostart.sh + start-local.sh and wire into .bashrc
& $WSL -u root -- bash -c "cp '$wslScript/autostart.sh' '$wslScript/start-local.sh' $IKUKU_DIR/ 2>/dev/null; sed -i 's/\r//' $IKUKU_DIR/autostart.sh $IKUKU_DIR/start-local.sh; chmod +x $IKUKU_DIR/autostart.sh $IKUKU_DIR/start-local.sh 2>/dev/null; if ! grep -q autostart.sh /root/.bashrc 2>/dev/null; then echo 'source $IKUKU_DIR/autostart.sh' >> /root/.bashrc; fi"

# Step 3: Register startup task
Write-Host "Registering startup task..."
& "$sharedDir\service-setup.ps1" -TaskName "ikuku" -ServiceScript "$scriptDir\ikuku-service.ps1"

# Step 4: Disable sleep mode
Write-Host "Disabling sleep mode..."
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0

# Step 5: Firewall rule
netsh advfirewall firewall add rule name="ikuku" dir=in action=allow protocol=TCP localport=$($conf.LMS_PORT)
netsh advfirewall firewall add rule name="ikuku-progress" dir=in action=allow protocol=TCP localport=8080

# Step 6: Copy activate.sh and start Kiro engagement in WSL terminal
Write-Host "Starting containers and Kiro engagement..."
& $WSL -u root -- bash -c "cp '$wslScript/activate.sh' $IKUKU_DIR/; sed -i 's/\r//' $IKUKU_DIR/activate.sh; chmod +x $IKUKU_DIR/activate.sh"
# Keep progress page as fallback (accessible at :8080 if needed)
& $WSL -u root -- bash -c "cp '$wslScript/progress.py' '$wslScript/progress.html' $IKUKU_DIR/ 2>/dev/null" 2>&1 | Out-Null

# Step 7: Start containers in background (tray app monitors progress)
Write-Host "Starting containers in background (tray app will show when ready)..."
& $WSL -u root -- bash -c "cd $IKUKU_DIR; nohup podman-compose up -d > /tmp/ikuku-compose.log 2>&1 &"

# Step 8: Open WSL terminal with Kiro
Write-Host "Opening Kiro terminal..."
$hasWT = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($hasWT) {
    Start-Process "wt.exe" -ArgumentList "wsl.exe -u root -- bash /opt/ikuku/activate.sh" -ErrorAction SilentlyContinue
} else {
    Start-Process "cmd.exe" -ArgumentList "/c wsl.exe -u root -- bash /opt/ikuku/activate.sh"
}

Start-Sleep 3
$wslIp = (& $WSL -u root -- hostname -I).Trim().Split(' ')[0]
netsh interface portproxy add v4tov4 listenport=8080 listenaddress=0.0.0.0 connectport=8080 connectaddress=$wslIp 2>&1 | Out-Null
netsh interface portproxy add v4tov4 listenport=8000 listenaddress=0.0.0.0 connectport=8000 connectaddress=$wslIp 2>&1 | Out-Null
$ErrorActionPreference = "Stop"

# Build access URLs
$routes = @()
$Apps -split ',' | ForEach-Object {
    $app = $_.Trim()
    switch ($app) {
        "lms"     { $routes += "/lms" }
        "wiki"    { $routes += "/wiki/" }
        "erpnext" { $routes += "/app" }
        "crm"     { $routes += "/crm" }
        default   { $routes += "/app" }
    }
}

Write-Host ""
Write-Host "=== ikuku installed! ===" -ForegroundColor Green
Write-Host "Port: $($conf.LMS_PORT)"
$urlList = ""
foreach ($r in $routes) {
    Write-Host "  http://localhost:$($conf.LMS_PORT)$r"
    $urlList += "  http://localhost:$($conf.LMS_PORT)$r`n"
}
Write-Host "LAN: http://$($env:COMPUTERNAME):$($conf.LMS_PORT)"
Write-Host "Login: Administrator / admin"
Write-Host ""
Write-Host "IMPORTANT: First startup takes 5-10 minutes while apps are compiled." -ForegroundColor Yellow
Write-Host "Refresh the browser if you see a blank page or connection error." -ForegroundColor Yellow
Write-Host ""
$uninstMsg = "To uninstall: powershell -File " + $scriptDir + "\uninstall.ps1"
Write-Host $uninstMsg -ForegroundColor DarkGray

# Signal tray app: install complete, containers starting
# Signal tray app: containers starting, will poll for ready
# Background task writes 'active' when ERPNext responds
& $WSL -u root -- bash -c "nohup bash -c 'while ! curl -sf http://localhost:8000 > /dev/null 2>&1; do sleep 10; done; echo active > /mnt/c/ikuku/status.txt' > /tmp/ikuku-ready-poll.log 2>&1 &"
