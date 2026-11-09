# ConfigMgr Application detection method: run in 64-bit PowerShell, as SYSTEM.
# ConfigMgr considers the application installed only if exit 0 AND output is present.
$engine=Join-Path $PSScriptRoot 'Invoke-AutodeskCleanup.ps1'
& $engine -Mode Detect -MinimumKeepYear 2000
if ($LASTEXITCODE -eq 0) { Write-Output 'Autodesk version cleanup compliant' }
exit 0
