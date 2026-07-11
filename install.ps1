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
Write-Host "Apps: $Apps | Port: $($conf.LMS_PORT)"

# Step 0: Check WSL2 + container support
$errors = @()
if (-not $WSL) {
    $errors += "WSL is not installed. Install from https://aka.ms/wslinstall"
} else {
# Basic WSL check
$wslCheck = & $WSL --status 2>&1 | Out-String
if ($wslCheck -match "not supported|not enabled") {
    $errors += "WSL2 is not available on this system."
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

# Step 2: Copy docker config into WSL with selected apps
Write-Host "Setting up Frappe in WSL..."
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR"
$wslScript = (& $WSL -u root -- wslpath -a ($scriptDir -replace '\\','/')).Trim()
& $WSL -u root -- bash -c "cp '$wslScript/docker-compose.yml' '$wslScript/init.sh' $IKUKU_DIR/; tr -d '\r' < $IKUKU_DIR/init.sh > $IKUKU_DIR/init.sh.tmp; mv $IKUKU_DIR/init.sh.tmp $IKUKU_DIR/init.sh"
# Copy shared/ (kiro-cli, bind.tar.gz, next-sale.bundle) - self-contained, no runtime downloads
$wslShared = (& $WSL -u root -- wslpath -a ($sharedDir -replace '\\','/')).Trim()
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR/shared; cp '$wslShared/kiro-cli' '$wslShared/kiro-cli-chat' '$wslShared/bind.tar.gz' $IKUKU_DIR/shared/ 2>/dev/null; if [ -f '$wslShared/next-sale.bundle' ]; then cp '$wslShared/next-sale.bundle' $IKUKU_DIR/shared/; fi"
# Copy ikuku.conf if present (contains activation code baked by evalKit)
& $WSL -u root -- bash -c "if [ -f '$wslScript/ikuku.conf' ]; then cp '$wslScript/ikuku.conf' $IKUKU_DIR/; tr -d '\r' < $IKUKU_DIR/ikuku.conf > $IKUKU_DIR/ikuku.conf.tmp 2>/dev/null; mv $IKUKU_DIR/ikuku.conf.tmp $IKUKU_DIR/ikuku.conf 2>/dev/null; fi"
# Write selected apps into .env for docker-compose
& $WSL -u root -- bash -c "echo 'IKUKU_APPS=$Apps' > $IKUKU_DIR/.env"

# Pre-create .ikuku directory with write permissions for frappe user (UID 1000)
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR/.ikuku; chmod 777 $IKUKU_DIR/.ikuku"

# Copy autostart.sh + start-local.sh and wire into .bashrc
& $WSL -u root -- bash -c "cp '$wslScript/autostart.sh' '$wslScript/start-local.sh' $IKUKU_DIR/ 2>/dev/null; chmod +x $IKUKU_DIR/autostart.sh $IKUKU_DIR/start-local.sh 2>/dev/null; if ! grep -q autostart.sh /root/.bashrc 2>/dev/null; then echo 'source $IKUKU_DIR/autostart.sh' >> /root/.bashrc; fi"

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
& $WSL -u root -- bash -c "cp '$wslScript/activate.sh' $IKUKU_DIR/; chmod +x $IKUKU_DIR/activate.sh"
# Keep progress page as fallback (accessible at :8080 if needed)
& $WSL -u root -- bash -c "cp '$wslScript/progress.py' '$wslScript/progress.html' $IKUKU_DIR/ 2>/dev/null" 2>&1 | Out-Null

# Step 7: Start containers (background - activate.sh will engage user while this runs)
Write-Host "Starting containers (first boot - this pulls images and takes 5-10 min)..."
& $WSL -u root -- bash -c "cd $IKUKU_DIR; podman-compose up -d 2>&1 | tail -5"

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
& $WSL -u root -- bash -c 'echo active > /mnt/c/ikuku/status.txt'
