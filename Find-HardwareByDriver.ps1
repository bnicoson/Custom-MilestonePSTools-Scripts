# Find-HardwareByDriver.ps1
# Pick a recording server and list all hardware on it that use a given driver number.

$DriverNumber = 689   # change to target a different driver

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Pick the recording server ---
$recorder = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select a recording server" -OutputMode Single

if ($null -eq $recorder) {
    Write-Warning "No recording server selected. Nothing to do."
    return
}

Write-Host "Scanning '$($recorder.Name)' for hardware using driver $DriverNumber ..." -ForegroundColor Cyan

# --- Find hardware on that server using the target driver ---
$matches = foreach ($hw in ($recorder | Get-VmsHardware)) {
    $drv = $hw | Get-VmsHardwareDriver
    if ($drv.Number -eq $DriverNumber) {
        [pscustomobject]@{
            Name      = $hw.Name
            Address   = $hw.Address
            Enabled   = $hw.Enabled
            Driver    = $drv.Name
            DriverNum = $drv.Number
            Guid      = $hw.Id
        }
    }
}

if (-not $matches) {
    Write-Warning "No hardware on '$($recorder.Name)' is using driver $DriverNumber."
    return
}

Write-Host "Found $($matches.Count) device(s) using driver $DriverNumber on '$($recorder.Name)'.`n" -ForegroundColor Yellow

$matches |
    Sort-Object Name |
    Out-GridView -Title "Driver $DriverNumber hardware on $($recorder.Name)"
