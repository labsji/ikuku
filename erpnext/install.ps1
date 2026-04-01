# install.ps1 - Install Frappe ERPNext on Windows via WSL2 + Podman
$ErrorActionPreference = "Stop"
$WSL = "wsl.exe"
$LMS_DIR = "/opt/frappe-erpnext"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sharedDir = Join-Path $scriptDir "..\shared"
if (!(Test-Path $sharedDir)) { $sharedDir = Join-Path $scriptDir "shared" }

# Read config from wizard (or use defaults)
$conf = @{ SITE_NAME="lms.local"; ADMIN_EMAIL="admin@example.com"; ADMIN_PASSWORD="admin"; LMS_PORT="8000" }
$confFile = Join-Path $scriptDir "erpnext.conf"
if (Test-Path $confFile) {
    Get-Content $confFile | ForEach-Object {
        $k, $v = $_ -split '=', 2
        if ($k -and $v) { $conf[$k.Trim()] = $v.Trim() }
    }
}

Write-Host "=== Installing Frappe ERPNext ===" -ForegroundColor Cyan
Write-Host "Site: $($conf.SITE_NAME) | Port: $($conf.LMS_PORT)"

# Step 0: Check WSL2 support
$wslVersion = & $WSL -l -v 2>&1 | Out-String
if ($wslVersion -match "VERSION\s+1" -and $wslVersion -notmatch "VERSION\s+2") {
    Write-Host "WARNING: WSL is running in version 1 mode." -ForegroundColor Yellow
    Write-Host "Frappe ERPNext requires WSL2 (needs hardware virtualization / Hyper-V)."
    Write-Host "On physical machines: enable virtualization in BIOS and run 'wsl --set-default-version 2'"
    Write-Host "On VMs: ensure nested virtualization is enabled."
}

# Step 1: WSL2 + Ubuntu + Podman (shared across all Frappe apps)
Write-Host "Setting up WSL2 + Podman..."
& "$sharedDir\wsl-setup.ps1" -MemoryGB 12 -SwapGB 4

# Step 2: Copy docker config into WSL
Write-Host "Setting up LMS in WSL..."
& $WSL -u root -- bash -c "mkdir -p $LMS_DIR"
$dockerDir = Join-Path $scriptDir "docker"
if (Test-Path $dockerDir) {
    $wslPath = (& $WSL -u root -- wslpath -a ($dockerDir -replace '\\','/')).Trim()
    & $WSL -u root -- bash -c "cp -r $wslPath/* $LMS_DIR/"
}
# Ensure dependencies (payments) are resolved when fetching lms
& $WSL -u root -- bash -c "sed -i 's/bench get-app lms/bench get-app --resolve-deps lms/' $LMS_DIR/init.sh"

# Step 3: Register startup task (shared S4U scheduled task)
Write-Host "Registering startup task..."
& "$sharedDir\service-setup.ps1" -TaskName "FrappeERPNext" -ServiceScript "$scriptDir\erpnext-service.ps1"

# Step 4: Disable sleep mode
Write-Host "Disabling sleep mode..."
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0

# Step 5: Firewall rule (port proxy is handled by erpnext-service.ps1 on every boot)
netsh advfirewall firewall add rule name="Frappe-ERPNext" dir=in action=allow protocol=TCP localport=$($conf.LMS_PORT)

Write-Host ""
Write-Host "=== Frappe ERPNext installed! ===" -ForegroundColor Green
Write-Host "Access at: http://erp.localhost:$($conf.LMS_PORT)/app"
Write-Host "Or from LAN: http://$($env:COMPUTERNAME):$($conf.LMS_PORT)/app"
Write-Host ""
Write-Host "Task: FrappeERPNext (auto-starts on boot, keeps WSL alive)"
Write-Host "Sleep mode: disabled"
Write-Host ""
Write-Host "To uninstall: powershell -File `"$scriptDir\uninstall.ps1`"" -ForegroundColor DarkGray
