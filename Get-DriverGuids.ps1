# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# Pick the recording server
$recorder = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select a recording server" -OutputMode Single

if ($null -eq $recorder) {
    Write-Warning "No recording server selected. Nothing to do."
    return
}

Write-Host "Retrieving drivers on '$($recorder.Name)'..." -ForegroundColor Cyan

# Get all drivers on that server and show their GUIDs
$recorder |
    Get-VmsHardwareDriver |
    Select-Object Name, Number, Guid, DriverVersion, DriverRevision, GroupName |
    Sort-Object GroupName, Name |
    Out-GridView -Title "Drivers on $($recorder.Name)"
