# install.ps1 - ikuku: install Frappe apps on Windows
# Usage: powershell -File install.ps1 -Apps "wiki,lms"
param([string]$Apps = "wiki")

$ErrorActionPreference = "Stop"
$WSL = "wsl.exe"
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
Write-Host "Apps: $Apps | Port: $($conf.LMS_PORT)"

# Step 0: Check WSL2
$wslCheck = & $WSL --status 2>&1 | Out-String
$wslVersion = & $WSL -l -v 2>&1 | Out-String
$errors = @()
if ($wslCheck -match "not supported" -or $wslCheck -match "not enabled" -or $wslCheck -match "error") {
    $errors += "WSL2 is not available on this system."
}
if ($wslVersion -match "VERSION\s+1" -and $wslVersion -notmatch "VERSION\s+2") {
    $errors += "WSL is running in version 1 mode. WSL2 required."
}
# Check hardware virtualization
$hyperv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if (-not $hyperv) {
    $errors += "Hardware virtualization (Hyper-V) is not enabled or not supported."
}
if ($errors.Count -gt 0) {
    $msg = "ikuku cannot install:`n`n" + ($errors -join "`n") + "`n`nRequirements:`n- Windows 10/11 or Server 2019+`n- Hardware virtualization enabled in BIOS`n- WSL2 (not WSL1)`n`nFiles have been extracted to: $scriptDir"
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
    $wslBundle = (& wsl.exe -u root -- wslpath -a ($bundleDir -replace '\\','/')).Trim()
    & wsl.exe -u root -- bash -c "ln -sf '$wslBundle' /tmp/ikuku-bundle; podman load -i /tmp/ikuku-bundle/img-mariadb.tar; podman load -i /tmp/ikuku-bundle/img-redis.tar; cat /tmp/ikuku-bundle/img-bench.tar.part* | podman load"
}

# Step 2: Copy docker config into WSL with selected apps
Write-Host "Setting up Frappe in WSL..."
& $WSL -u root -- bash -c "mkdir -p $IKUKU_DIR"
$wslScript = (& $WSL -u root -- wslpath -a ($scriptDir -replace '\\','/')).Trim()
& $WSL -u root -- bash -c "cp '$wslScript/docker-compose.yml' '$wslScript/init.sh' $IKUKU_DIR/; sed -i 's/\r//g' $IKUKU_DIR/init.sh"
# Write selected apps into .env for docker-compose
& $WSL -u root -- bash -c "echo 'IKUKU_APPS=$Apps' > $IKUKU_DIR/.env"

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
Write-Host ("To uninstall: powershell -File " + $scriptDir + "\uninstall.ps1") -ForegroundColor DarkGray

Add-Type -AssemblyName System.Windows.Forms
$successMsg = "ikuku installed successfully!`n`n$urlList`nLAN: http://$($env:COMPUTERNAME):$($conf.LMS_PORT)`nLogin: Administrator / admin`n`nNote: First startup may take a few minutes."
[System.Windows.Forms.MessageBox]::Show($successMsg, "ikuku - Installation Complete", "OK", "Information") | Out-Null
