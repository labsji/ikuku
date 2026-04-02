# start.ps1 — Start ikuku
schtasks /run /tn "ikuku" 2>$null
Start-ScheduledTask -TaskName "ikuku" 2>$null
Write-Host "ikuku starting."
