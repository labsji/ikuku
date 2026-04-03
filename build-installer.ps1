# build-installer.ps1 — Build ikuku installer
param([ValidateSet("lite","full")][string]$Variant = "lite")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$makensis = "C:\Program Files (x86)\NSIS\makensis.exe"
if (!(Test-Path $makensis)) { $makensis = "makensis" }

& $makensis /DVARIANT=$Variant ikuku-installer.nsi
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }

$outFile = "ikuku-$Variant.exe"
if (!(Test-Path $outFile)) { throw "Output file $outFile not found" }
Write-Host "Built: $outFile ($('{0:N1} MB' -f ((Get-Item $outFile).Length / 1MB)))" -ForegroundColor Green
