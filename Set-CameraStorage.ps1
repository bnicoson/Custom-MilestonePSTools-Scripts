# Set-CameraStorage.ps1
# Pick a recording server, select cameras via GridView, pick a target storage via GridView,
# then reassign the selected cameras to that storage.
#
# NOTE: Storage configurations belong to a specific recording server, so a camera can only
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

# --- Map storage paths -> names on this server (for showing each camera's current storage) ---
$storages = @($recorder | Get-VmsStorage)
if (-not $storages) {
    Write-Warning "No storage configurations found on '$($recorder.Name)'."
    return
}
$storeByPath = @{}
foreach ($s in $storages) { $storeByPath[$s.Path] = $s.Name }

Write-Host "Loading cameras on '$($recorder.Name)'..." -ForegroundColor Cyan

# --- Build camera rows, keeping a reference to the real camera object ---
$cameraRows = foreach ($hw in ($recorder | Get-VmsHardware)) {
    foreach ($cam in ($hw | Get-VmsCamera -EnableFilter All)) {
        [pscustomobject]@{
            Camera         = $cam                                   # live object (not shown in grid)
            Name           = $cam.Name
            HardwareName   = $hw.Name
            Enabled        = $cam.Enabled
            CurrentStorage = if ($storeByPath.ContainsKey($cam.RecordingStorage)) { $storeByPath[$cam.RecordingStorage] } else { $cam.RecordingStorage }
            Id             = $cam.Id
        }
    }
}

if (-not $cameraRows) {
    Write-Warning "No cameras found on '$($recorder.Name)'."
    return
}

# --- Select cameras to move ---
$picked = $cameraRows |
    Select-Object Name, HardwareName, Enabled, CurrentStorage, Id |
    Sort-Object Name |
    Out-GridView -Title "Select cameras to move (Ctrl/Shift for multiple) - $($recorder.Name)" -OutputMode Multiple

if (-not $picked) {
    Write-Host "No cameras selected. No changes made." -ForegroundColor Red
    return
}

# --- Select the target storage ---
$targetStorage = $storages |
    Select-Object Name, @{n='UsedSpace';e={$_.UsedSpace}}, Path |
    Sort-Object Name |
    Out-GridView -Title "Select the TARGET storage on $($recorder.Name)" -OutputMode Single

if (-not $targetStorage) {
    Write-Host "No target storage selected. No changes made." -ForegroundColor Red
    return
}

# --- Map picked rows back to the live camera objects ---
$byId = @{}
foreach ($row in $cameraRows) { $byId[$row.Id] = $row.Camera }
$targetCams = foreach ($p in $picked) { $byId[$p.Id] }

$confirm = Read-Host "Move $($picked.Count) camera(s) to storage '$($targetStorage.Name)' on '$($recorder.Name)'? (yes/no)"
if ($confirm -ne 'yes') {
    Write-Host "Cancelled. No changes made." -ForegroundColor Red
    return
}

# --- Apply ---
$results = $targetCams |
    Set-VmsDeviceStorage -Destination $targetStorage.Name -PassThru -Confirm:$false -Verbose

Write-Host "`nDone. Reassigned $(@($results).Count) camera(s) to '$($targetStorage.Name)'." -ForegroundColor Green
Write-Host "Reminder: existing recordings stay in the old storage and age out; only new recordings use the new storage." -ForegroundColor DarkYellow
