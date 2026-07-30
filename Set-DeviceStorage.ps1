# Set-DeviceStorage.ps1
# Pick a recording server, select devices via GridView, pick a target storage via GridView,
# then reassign the selected devices to that storage. Handles ALL recording device types on
# the hardware - cameras, microphones, speakers, and metadata (inputs/outputs don't record,
# so they have no storage).
#
# NOTE: Storage configurations belong to a specific recording server, so a device can only
# be moved to a storage that exists on its own recorder - hence the server-first selection.
# NOTE: Existing recordings are NOT moved. They stay in the old storage and age out per that
# storage's retention. Only new recordings go to the new storage. (Per Milestone docs.)

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

# --- Map storage paths -> names on this server (for showing each device's current storage) ---
$storages = @($recorder | Get-VmsStorage)
if (-not $storages) {
    Write-Warning "No storage configurations found on '$($recorder.Name)'."
    return
}
$storeByPath = @{}
foreach ($s in $storages) { $storeByPath[$s.Path] = $s.Name }

Write-Host "Loading devices on '$($recorder.Name)'..." -ForegroundColor Cyan

# --- Build device rows across all recording device types, keeping the real device object ---
$deviceRows = foreach ($hw in ($recorder | Get-VmsHardware)) {
    $typed = @()
    $typed += @($hw | Get-VmsCamera     -EnableFilter All -ErrorAction SilentlyContinue) | ForEach-Object { @{ Type = 'Camera';     Dev = $_ } }
    $typed += @($hw | Get-VmsMicrophone -EnableFilter All -ErrorAction SilentlyContinue) | ForEach-Object { @{ Type = 'Microphone'; Dev = $_ } }
    $typed += @($hw | Get-VmsSpeaker    -EnableFilter All -ErrorAction SilentlyContinue) | ForEach-Object { @{ Type = 'Speaker';    Dev = $_ } }
    $typed += @($hw | Get-VmsMetadata   -EnableFilter All -ErrorAction SilentlyContinue) | ForEach-Object { @{ Type = 'Metadata';   Dev = $_ } }

    foreach ($t in $typed) {
        $dev = $t.Dev
        if (-not $dev) { continue }
        [pscustomobject]@{
            Device         = $dev                                   # live object (not shown in grid)
            DeviceType     = $t.Type
            Name           = $dev.Name
            HardwareName   = $hw.Name
            Enabled        = $dev.Enabled
            CurrentStorage = if ($storeByPath.ContainsKey($dev.RecordingStorage)) { $storeByPath[$dev.RecordingStorage] } else { $dev.RecordingStorage }
            Id             = $dev.Id
        }
    }
}

if (-not $deviceRows) {
    Write-Warning "No devices found on '$($recorder.Name)'."
    return
}

# --- Select devices to move ---
$picked = $deviceRows |
    Select-Object DeviceType, Name, HardwareName, Enabled, CurrentStorage, Id |
    Sort-Object HardwareName, DeviceType, Name |
    Out-GridView -Title "Select devices to move (Ctrl/Shift for multiple) - $($recorder.Name)" -OutputMode Multiple

if (-not $picked) {
    Write-Host "No devices selected. No changes made." -ForegroundColor Red
    return
}

# --- Select the target storage ---
$targetStorage = $storages |
    Select-Object Name, Path |
    Sort-Object Name |
    Out-GridView -Title "Select the TARGET storage on $($recorder.Name)" -OutputMode Single

if (-not $targetStorage) {
    Write-Host "No target storage selected. No changes made." -ForegroundColor Red
    return
}

# --- Map picked rows back to the live device objects ---
$byId = @{}
foreach ($row in $deviceRows) { $byId[$row.Id] = $row.Device }
$targetDevices = foreach ($p in $picked) { $byId[$p.Id] }

$confirm = Read-Host "Move $($picked.Count) device(s) to storage '$($targetStorage.Name)' on '$($recorder.Name)'? (yes/no)"
if ($confirm -ne 'yes') {
    Write-Host "Cancelled. No changes made." -ForegroundColor Red
    return
}

# --- Apply (Set-VmsDeviceStorage accepts cameras, mics, speakers, and metadata together) ---
$results = $targetDevices |
    Set-VmsDeviceStorage -Destination $targetStorage.Name -PassThru -Confirm:$false -Verbose

Write-Host "`nDone. Reassigned $(@($results).Count) device(s) to '$($targetStorage.Name)'." -ForegroundColor Green
Write-Host "Reminder: existing recordings stay in the old storage and age out; only new recordings use the new storage." -ForegroundColor DarkYellow
