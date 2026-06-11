Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula

Write-Host "Retrieving all hardware..." -ForegroundColor Cyan
$AllHardware = @(Get-VmsHardware)
Write-Host "Found $($AllHardware.Count) device(s).`n" -ForegroundColor Yellow

$newDriver = Get-VmsRecordingServer |
    Select-Object -First 1 |
    Get-VmsHardwareDriver |
    Out-GridView -Title "Select driver to apply to all hardware" -OutputMode Single

if ($null -eq $newDriver) {
    Write-Warning "No driver selected. No changes will be made."
    return
}

$confirm = Read-Host "Apply '$($newDriver.Name)' to ALL $($AllHardware.Count) device(s)? (yes/no)"
if ($confirm -ne 'yes') {
    Write-Host "Cancelled." -ForegroundColor Red
    exit
}

$AllHardware | Set-VmsHardwareDriver -Driver $newDriver -Confirm:$false
Write-Host "Driver replacement complete." -ForegroundColor Green
