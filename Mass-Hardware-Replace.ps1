Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force

Write-Host "Retrieving all hardware..." -ForegroundColor Cyan
$AllHardware = @(Get-VmsHardware)
Write-Host "Found $($AllHardware.Count) device(s)." -ForegroundColor Yellow

$confirm = Read-Host "`nThis will auto-replace drivers on ALL $($AllHardware.Count) device(s). Continue? (yes/no)"
if ($confirm -ne 'yes') {
    Write-Host "Cancelled." -ForegroundColor Red
    exit
}

$AllHardware | Set-VmsHardwareDriver -Confirm:$false
Write-Host "Driver replacement complete." -ForegroundColor Green
