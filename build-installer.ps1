# build-installer.ps1 — Build ikuku installer (supports white-label)
param([ValidateSet("lite","full")][string]$Variant = "lite")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$makensis = "C:\Program Files (x86)\NSIS\makensis.exe"
if (!(Test-Path $makensis)) { $makensis = "makensis" }

# Read white-label config if present
$wlArgs = ""
$confFile = Join-Path $scriptDir "whitelabel.conf"
if (Test-Path $confFile) {
    Write-Host "Reading white-label config..." -ForegroundColor Cyan
    $conf = @{}
    Get-Content $confFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$') {
            $conf[$Matches[1]] = $Matches[2].Trim()
        }
    }
    if ($conf.INSTALLER_TITLE) { $wlArgs += " /DWLTITLE=`"$($conf.INSTALLER_TITLE)`"" }
    if ($conf.COMPANY_NAME) { $wlArgs += " /DWLCOMPANY=`"$($conf.COMPANY_NAME)`"" }
    if ($conf.CONTACT_EMAIL) { $wlArgs += " /DWLEMAIL=`"$($conf.CONTACT_EMAIL)`"" }
    if ($conf.CONTACT_PHONE) { $wlArgs += " /DWLPHONE=`"$($conf.CONTACT_PHONE)`"" }
    if ($conf.WEBSITE) { $wlArgs += " /DWLWEBSITE=`"$($conf.WEBSITE)`"" }
    Write-Host "  Brand: $($conf.INSTALLER_TITLE)" -ForegroundColor Cyan
}

$cmd = "& `"$makensis`" /DVARIANT=$Variant $wlArgs ikuku-installer.nsi"
Write-Host $cmd
Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }

$outFile = "ikuku-$Variant.exe"
if (!(Test-Path $outFile)) { throw "Output file $outFile not found" }
Write-Host "Built: $outFile ($('{0:N1} MB' -f ((Get-Item $outFile).Length / 1MB)))" -ForegroundColor Green
