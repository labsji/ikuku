# build-installer.ps1 — Build ikuku installer
param([ValidateSet("lite","full")][string]$Variant = "lite")

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$makensis = "makensis"
if (Test-Path "C:\Program Files (x86)\NSIS\makensis.exe") { $makensis = "C:\Program Files (x86)\NSIS\makensis.exe" }

& $makensis /DVARIANT=$Variant ikuku-installer.nsi

$outFile = "ikuku-$Variant.exe"
if (Test-Path $outFile) {
    Write-Host "Built: $outFile ($('{0:N1} MB' -f ((Get-Item $outFile).Length / 1MB)))" -ForegroundColor Green
}
