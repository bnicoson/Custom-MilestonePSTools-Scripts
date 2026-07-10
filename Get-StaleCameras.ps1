# Get-StaleCameras.ps1
# Companion to Compare-CameraHealth.ps1. Flags cameras that appear to have a recording
# problem, based on how long since they last recorded footage.
#
# Flags:
#   STALE  - camera is OFFLINE now AND has never recorded, or its last recording is older
#            than the threshold. (Down for a while.)
#   CHECK  - camera is ONLINE with recording enabled, but has never recorded or nothing since
#            the threshold, AND its hardware was NOT changed in the last 2 days. (Online but
#            silent - a potential problem worth checking.)
#   New HW - same as CHECK but the hardware was modified in the last 2 days, so no recording
#            yet is probably just because the camera was recently added/replaced.
#   Rec Off- recording is disabled on the camera, so no recorded footage is expected. This is
#            intentional (e.g. only the 360 view of a panoramic records; the de-warped sub-
#            views come in live only). Shown separately so they don't look like failures.
#   (blank)- recording recently, or status unknown -> not flagged.
#
# "Last recorded" = MediaDatabaseEnd from Get-VmsCameraReport (UTC time of the last recorded
# image); the best available proxy for "last seen" (Milestone exposes no true "last connected"
# time). A connected camera that is motion/event-only with no motion can legitimately show an
# old last-recorded time - the RecordingEnabled column and CHECK flag help you triage those.

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# --- Helpers ---
function Get-OnlineState {
    param($Row)
    $hasStatus = -not [string]::IsNullOrWhiteSpace("$($Row.StatusTime)")
    if (-not $hasStatus) { return 'Unknown' }
    if ($Row.ErrorNoConnection -eq $true -or $Row.IsStarted -ne $true) { return 'Offline' }
    return 'Online'
}
function Format-Guid { param($g); if (-not $g) { return '' }; return (("$g").Trim('{', '}')).ToLower() }

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Pick recording servers ---
$recorders = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select recording server(s) (select all for everything)" -OutputMode Multiple
if (-not $recorders) { Write-Warning "No recording server selected. Nothing to do."; return }

# --- Threshold ---
$thrEntry = Read-Host "Flag cameras with no recording in the last N days (Enter for 7)"
$threshold = if ([string]::IsNullOrWhiteSpace($thrEntry)) { 7 } else { ($thrEntry -as [int]) }
if ($null -eq $threshold) { $threshold = 7 }
$NewHwDays = 2   # hardware modified within this many days => treat "no recording yet" as expected (New HW)

# --- Hardware last-modified lookup (to spot recently added/replaced cameras) ---
Write-Host "Loading hardware..." -ForegroundColor Cyan
$hwModById = @{}
foreach ($rec in $recorders) {
    foreach ($hw in ($rec | Get-VmsHardware)) { $hwModById[(Format-Guid $hw.Id)] = $hw.LastModified }
}

Write-Host "Building report (retention info makes this slower on large systems)..." -ForegroundColor Cyan
$report = Get-VmsCameraReport -RecordingServer $recorders -IncludeRetentionInfo -Verbose

$nowUtc = (Get-Date).ToUniversalTime()
$rows = foreach ($r in $report) {
    $end = $r.MediaDatabaseEnd -as [datetime]
    if ($end) {
        $days     = [math]::Round(($nowUtc - $end).TotalDays, 1)
        $lastRec  = $end.ToLocalTime()
        $sortDays = $days
    } else {
        $days     = $null
        $lastRec  = 'Never'
        $sortDays = [double]::MaxValue
    }
    $begin  = $r.MediaDatabaseBegin -as [datetime]
    $online = Get-OnlineState $r

    # Hardware last-modified age
    $hwMod  = $hwModById[(Format-Guid $r.HardwareId)]
    if ($hwMod -is [datetime]) {
        $hwDays     = [math]::Round(($nowUtc - $hwMod.ToUniversalTime()).TotalDays, 1)
        $hwRecent   = ($hwDays -le $NewHwDays)
        $hwModLocal = $hwMod.ToLocalTime()
    } else {
        $hwDays     = $null; $hwRecent = $false; $hwModLocal = ''
    }

    $noOrOld = ($null -eq $days) -or ($days -ge $threshold)

    if ($r.RecordingEnabled -eq $false) {
        $flag = 'Rec Off'                              # recording disabled -> no footage expected
    } elseif ($online -eq 'Offline' -and $noOrOld) {
        $flag = 'STALE'
    } elseif ($online -eq 'Online' -and $noOrOld) {
        $flag = if ($hwRecent) { 'New HW' } else { 'CHECK' }
    } else {
        $flag = ''
    }

    [pscustomobject]@{
        Flag                = $flag
        Camera              = $r.Name
        HardwareName        = $r.HardwareName
        RecorderName        = $r.RecorderName
        Online              = $online
        RecordingEnabled    = $r.RecordingEnabled
        DaysSinceLastRecord = $days
        LastRecorded        = $lastRec
        FirstRecorded       = if ($begin) { $begin.ToLocalTime() } else { '' }
        HwLastModified      = $hwModLocal
        DaysSinceHwUpdate   = $hwDays
        Address             = $r.Address
        Model               = $r.Model
        SortDays            = $sortDays
    }
}
$rows = @($rows)
if (-not $rows) { Write-Warning "No cameras found."; return }

$rankFlag = @{ 'STALE' = 0; 'CHECK' = 1; 'New HW' = 2; 'Rec Off' = 3; '' = 4 }
foreach ($row in $rows) { $row | Add-Member -NotePropertyName FlagRank -NotePropertyValue ($rankFlag[$row.Flag]) -Force }

$stale  = @($rows | Where-Object Flag -eq 'STALE').Count
$check  = @($rows | Where-Object Flag -eq 'CHECK').Count
$newhw  = @($rows | Where-Object Flag -eq 'New HW').Count
$recoff = @($rows | Where-Object Flag -eq 'Rec Off').Count
Write-Host ("`n{0} camera(s): {1} STALE, {2} CHECK (online but silent), {3} New HW, {4} Rec Off (intentional).`n" -f $rows.Count, $stale, $check, $newhw, $recoff) -ForegroundColor Yellow

$sorted = $rows |
    Sort-Object FlagRank, @{ Expression = 'SortDays'; Descending = $true }, RecorderName, HardwareName, Camera |
    Select-Object Flag, Camera, HardwareName, RecorderName, Online, RecordingEnabled, DaysSinceLastRecord, LastRecorded, FirstRecorded, HwLastModified, DaysSinceHwUpdate, Address, Model

$sorted | Out-GridView -Title "Camera recording health  (threshold: $threshold days)"

# --- Optional CSV export ---
$answer = Read-Host "Export to CSV? (y/N)"
if ($answer -match '^(y|yes)$') {
    $stamp   = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
    $default = Join-Path $env:USERPROFILE "Downloads\StaleCameras_$stamp.csv"
    $path = Read-Host "Save to (press Enter for $default)"
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
    $sorted | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Exported to: $path" -ForegroundColor Green
}
