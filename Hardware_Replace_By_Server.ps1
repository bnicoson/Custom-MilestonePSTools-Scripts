# Ensure module is available
Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula

# Select recording servers
$recorders = Get-VmsRecordingServer | Out-GridView -Title "Select Recording Server(s)" -OutputMode Multiple

if ($null -eq $recorders) {
    Write-Warning "No recording server selected. No changes will be made."
    return
}

foreach ($rec in $recorders) {

    Write-Host "Processing Recording Server: $($rec.Name)" -ForegroundColor Cyan

    # Clear cache to ensure updated driver/hardware info
    $rec.HardwareDriverFolder.ClearChildrenCache()
    $rec.HardwareFolder.ClearChildrenCache()

    # Get all hardware on this recorder
    $hardware = Get-VmsHardware -RecordingServer $rec

    if ($hardware) {
        $hardware | Set-VmsHardwareDriver -Confirm:$false
        Write-Host "Drivers auto-replaced on $($hardware.Count) device(s)." -ForegroundColor Green
    }
    else {
        Write-Host "No hardware found on this recording server." -ForegroundColor Yellow
    }
}

Write-Host "Driver replacement complete." -ForegroundColor Green