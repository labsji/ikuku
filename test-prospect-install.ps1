# test-prospect-install.ps1 — Automated test of the prospect install experience
# Run on a fresh Win11 VM (e.g., AWS EC2 with Windows 11, or local Hyper-V)
#
# Prerequisites:
#   - WSL2 capable (Win11 22H2+ or Win10 19041+)
#   - Internet access for WSL install (first run only)
#   - ikuku-kiro-full.zip extracted alongside this script
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File test-prospect-install.ps1
#
# What it tests:
#   1. Silent install completes without error
#   2. ERPNext responds at localhost:8000 within 3 minutes
#   3. Login as Administrator/admin works
#   4. Kiro-cli is accessible inside the container
#   5. Data persists after stop/start (idempotency)

param(
    [string]$InstallDir = "C:\Program Files\ikuku",
    [int]$TimeoutSeconds = 180,
    [switch]$SkipInstall,
    [switch]$Cleanup
)

$ErrorActionPreference = "Stop"
$results = @()
$startTime = Get-Date

function Test-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host "`n--- TEST: $Name ---" -ForegroundColor Cyan
    try {
        $result = & $Action
        if ($result -eq $false) {
            Write-Host "  FAIL" -ForegroundColor Red
            $script:results += @{ Name = $Name; Status = "FAIL"; Detail = "Returned false" }
            return $false
        }
        Write-Host "  PASS" -ForegroundColor Green
        $script:results += @{ Name = $Name; Status = "PASS"; Detail = "" }
        return $true
    } catch {
        Write-Host "  FAIL: $_" -ForegroundColor Red
        $script:results += @{ Name = $Name; Status = "FAIL"; Detail = $_.ToString() }
        return $false
    }
}

# Find WSL
$WSL = $null
if (Test-Path "C:\Program Files\WSL\wsl.exe") { $WSL = "C:\Program Files\WSL\wsl.exe" }
elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) { $WSL = "wsl.exe" }

# --- TEST 0: WSL2 available ---
Test-Step "WSL2 available" {
    if (-not $WSL) { throw "wsl.exe not found" }
    $status = & $WSL --status 2>&1 | Out-String
    if ($status -match "not supported") { throw "WSL2 not supported on this machine" }
    return $true
}

# --- TEST 1: Silent install ---
if (-not $SkipInstall) {
    Test-Step "Silent install completes" {
        $scriptDir = Split-Path -Parent $MyInvocation.ScriptName
        # Look for the exe in current dir or parent
        $exe = Get-ChildItem -Path $scriptDir -Filter "ikuku-kiro-full.exe" -Recurse | Select-Object -First 1
        if (-not $exe) {
            # Try running install.ps1 directly (for dev testing)
            $installScript = Join-Path $scriptDir "install.ps1"
            if (-not (Test-Path $installScript)) {
                $installScript = "C:\Program Files\ikuku\install.ps1"
            }
            if (Test-Path $installScript) {
                & powershell -ExecutionPolicy Bypass -File $installScript -Apps "erpnext"
            } else {
                throw "No installer found. Place ikuku-kiro-full.exe or install.ps1 alongside this script."
            }
        } else {
            # Silent NSIS install
            Start-Process -FilePath $exe.FullName -ArgumentList "/S" -Wait -NoNewWindow
        }
        return $true
    }
}

# --- TEST 2: ERPNext responds within timeout ---
Test-Step "ERPNext responds at localhost:8000 (within ${TimeoutSeconds}s)" {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $responded = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:8000/api/method/frappe.ping" -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -eq 200) {
                $body = $resp.Content | ConvertFrom-Json
                if ($body.message -eq "pong") {
                    $responded = $true
                    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds)
                    Write-Host "  ERPNext responded in ${elapsed}s" -ForegroundColor Gray
                    break
                }
            }
        } catch { }
        Start-Sleep -Seconds 5
    }
    if (-not $responded) { throw "ERPNext did not respond within ${TimeoutSeconds}s" }
    return $true
}

# --- TEST 3: Login works ---
Test-Step "Login as Administrator/admin" {
    $loginBody = '{"usr":"Administrator","pwd":"admin"}'
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $resp = Invoke-WebRequest -Uri "http://localhost:8000/api/method/login" `
        -Method POST -Body $loginBody -ContentType "application/json" `
        -WebSession $session -UseBasicParsing -TimeoutSec 10
    if ($resp.StatusCode -ne 200) { throw "Login returned $($resp.StatusCode)" }
    $body = $resp.Content | ConvertFrom-Json
    if ($body.message -ne "Logged In") { throw "Unexpected response: $($body.message)" }
    return $true
}

# --- TEST 4: kiro-cli present in container ---
Test-Step "kiro-cli installed in frappe container" {
    $ver = & $WSL -u root -- bash -c "podman exec ikuku_frappe_1 /home/frappe/.local/bin/kiro-cli --version 2>&1"
    if ($ver -match "kiro-cli") {
        Write-Host "  Version: $ver" -ForegroundColor Gray
        return $true
    }
    throw "kiro-cli not found or errored: $ver"
}

# --- TEST 5: bind app installed ---
Test-Step "bind app present in ERPNext" {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri "http://localhost:8000/api/method/login" `
        -Method POST -Body '{"usr":"Administrator","pwd":"admin"}' `
        -ContentType "application/json" -WebSession $session -UseBasicParsing | Out-Null
    $resp = Invoke-WebRequest -Uri "http://localhost:8000/api/method/frappe.client.get_list" `
        -Method POST -Body '{"doctype":"Module Def","filters":{"module_name":"Bind"},"fields":["name"]}' `
        -ContentType "application/json" -WebSession $session -UseBasicParsing -TimeoutSec 10
    $body = $resp.Content | ConvertFrom-Json
    if ($body.message.Count -gt 0) { return $true }
    # Fallback: check if bind directory exists
    $check = & $WSL -u root -- bash -c "podman exec ikuku_frappe_1 test -d /home/frappe/frappe-bench/apps/bind && echo yes"
    if ($check -match "yes") { return $true }
    throw "bind app not found"
}

# --- TEST 6: Stop/start idempotency ---
Test-Step "Data persists after stop/start" {
    # Create a test customer
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri "http://localhost:8000/api/method/login" `
        -Method POST -Body '{"usr":"Administrator","pwd":"admin"}' `
        -ContentType "application/json" -WebSession $session -UseBasicParsing | Out-Null

    $custBody = '{"doctype":"Customer","customer_name":"Test Prospect Co","customer_type":"Company","customer_group":"All Customer Groups","territory":"All Territories"}'
    try {
        Invoke-WebRequest -Uri "http://localhost:8000/api/resource/Customer" `
            -Method POST -Body $custBody -ContentType "application/json" `
            -WebSession $session -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch {
        # May already exist from previous run — that's fine
    }

    # Stop containers
    Write-Host "  Stopping containers..." -ForegroundColor Gray
    & $WSL -u root -- bash -c "cd /opt/ikuku && podman-compose stop" 2>&1 | Out-Null
    Start-Sleep -Seconds 5

    # Start containers
    Write-Host "  Starting containers..." -ForegroundColor Gray
    & $WSL -u root -- bash -c "cd /opt/ikuku && podman-compose start" 2>&1 | Out-Null

    # Wait for ERPNext to come back
    $deadline = (Get-Date).AddSeconds(90)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:8000/api/method/frappe.ping" -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -eq 200) { $up = $true; break }
        } catch { }
        Start-Sleep -Seconds 5
    }
    if (-not $up) { throw "ERPNext did not come back after restart" }

    # Check customer still exists
    $session2 = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-WebRequest -Uri "http://localhost:8000/api/method/login" `
        -Method POST -Body '{"usr":"Administrator","pwd":"admin"}' `
        -ContentType "application/json" -WebSession $session2 -UseBasicParsing | Out-Null
    $resp = Invoke-WebRequest -Uri "http://localhost:8000/api/resource/Customer/Test Prospect Co" `
        -WebSession $session2 -UseBasicParsing -TimeoutSec 10
    if ($resp.StatusCode -eq 200) { return $true }
    throw "Customer not found after restart"
}

# --- SUMMARY ---
Write-Host "`n`n========================================" -ForegroundColor White
Write-Host "  TEST RESULTS" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
$pass = 0; $fail = 0
foreach ($r in $results) {
    $color = if ($r.Status -eq "PASS") { "Green" } else { "Red" }
    $detail = if ($r.Detail) { " — $($r.Detail)" } else { "" }
    Write-Host "  [$($r.Status)] $($r.Name)$detail" -ForegroundColor $color
    if ($r.Status -eq "PASS") { $pass++ } else { $fail++ }
}
$elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Write-Host ""
Write-Host "  $pass passed, $fail failed (${elapsed} min)" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
Write-Host "========================================" -ForegroundColor White

# Cleanup if requested
if ($Cleanup) {
    Write-Host "`nCleaning up..."
    & $WSL -u root -- bash -c "cd /opt/ikuku && podman-compose down -v" 2>&1 | Out-Null
    & $WSL -u root -- bash -c "rm -rf /opt/ikuku" 2>&1 | Out-Null
}

# Exit code
if ($fail -gt 0) { exit 1 }
exit 0
