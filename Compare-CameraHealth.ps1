# Compare-CameraHealth.ps1
# Two modes for capturing and comparing camera up/down status around maintenance/upgrades:
#
#   Snapshot : capture every (enabled) camera's online/offline status to a timestamped CSV.
#              Run once BEFORE an upgrade and once AFTER.
#   Compare  : pick the before + after snapshot CSVs and see what changed - especially
#              cameras that were online before but are DOWN after (the ones to go fix).
#
# Status comes from Get-VmsCameraReport (recorder status service, port 7563). Cameras are
# matched between snapshots by their VMS Id (GUID), which is stable across device-pack upgrades.

# Import module
Import-Module MilestonePSTools -ErrorAction Stop
Add-Type -AssemblyName System.Windows.Forms

# --- Helpers ---
function Select-CsvFile {
    param([string]$Title)
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = $Title
    $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dlg.InitialDirectory = (Join-Path $env:USERPROFILE 'Downloads')
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}
# Derive Online/Offline/Unknown from a camera report row.
function Get-OnlineState {
    param($Row)
    $hasStatus = -not [string]::IsNullOrWhiteSpace("$($Row.StatusTime)")
    if (-not $hasStatus) { return 'Unknown' }
    if ($Row.ErrorNoConnection -eq $true -or $Row.IsStarted -ne $true) { return 'Offline' }
    return 'Online'
}

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Choose mode ---
$mode = @(
    [pscustomobject]@{ Mode = 'Snapshot'; Description = 'Capture current camera status to a CSV (run before AND after an upgrade)' }
    [pscustomobject]@{ Mode = 'Compare';  Description = 'Diff a before + after snapshot to see what went down' }
) | Out-GridView -Title "Camera health - choose a mode" -OutputMode Single
if (-not $mode) { Write-Host "No mode chosen." -ForegroundColor Red; return }

# =====================================================================================
if ($mode.Mode -eq 'Snapshot') {
# =====================================================================================
    $recorders = Get-VmsRecordingServer |
        Sort-Object Name |
        Out-GridView -Title "Select recording server(s) to snapshot (select all for everything)" -OutputMode Multiple
    if (-not $recorders) { Write-Warning "No recording server selected. Nothing to do."; return }

    Write-Host "Capturing camera status (this can take a while on large systems)..." -ForegroundColor Cyan
    $report = Get-VmsCameraReport -RecordingServer $recorders -Verbose

    $snap = foreach ($r in $report) {
        [pscustomobject]@{
            Id                = $r.Id
            Camera            = $r.Name
            HardwareName      = $r.HardwareName
            RecorderName      = $r.RecorderName
            Online            = (Get-OnlineState $r)
            IsStarted         = $r.IsStarted
            ErrorNoConnection = $r.ErrorNoConnection
            ErrorNotLicensed  = $r.ErrorNotLicensed
            ErrorWritingGOP   = $r.ErrorWritingGOP
            IsInOverflow      = $r.IsInOverflow
            IsRecording       = $r.IsRecording
            StatusTime        = $r.StatusTime
        }
    }
    $snap = @($snap)

    $online  = @($snap | Where-Object Online -eq 'Online').Count
    $offline = @($snap | Where-Object Online -eq 'Offline').Count
    $unknown = @($snap | Where-Object Online -eq 'Unknown').Count
    Write-Host ("`n{0} camera(s): {1} online, {2} offline, {3} unknown.`n" -f $snap.Count, $online, $offline, $unknown) -ForegroundColor Yellow

    $snap | Sort-Object Online, RecorderName, HardwareName, Camera | Out-GridView -Title "Camera status snapshot"

    $stamp   = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
    $default = Join-Path $env:USERPROFILE "Downloads\CameraHealth_$stamp.csv"
    $path = Read-Host "Save snapshot to (press Enter for $default)"
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
    $snap | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Snapshot saved to: $path" -ForegroundColor Green
    Write-Host "Run this again after your upgrade, then use Compare mode on the two files." -ForegroundColor Cyan
}

# =====================================================================================
elseif ($mode.Mode -eq 'Compare') {
# =====================================================================================
    $beforePath = Select-CsvFile -Title "Select the BEFORE snapshot CSV"
    if (-not $beforePath) { Write-Host "No before file selected." -ForegroundColor Red; return }
    $afterPath  = Select-CsvFile -Title "Select the AFTER snapshot CSV"
    if (-not $afterPath) { Write-Host "No after file selected." -ForegroundColor Red; return }

    $before = @(Import-Csv $beforePath)
    $after  = @(Import-Csv $afterPath)

    $beforeById = @{}; foreach ($b in $before) { $beforeById[$b.Id] = $b }
    $afterById  = @{}; foreach ($a in $after)  { $afterById[$a.Id]  = $a }

    $allIds = @($before.Id + $after.Id | Sort-Object -Unique)

    $rank = @{ 'NEWLY DOWN' = 0; 'Still Down' = 1; 'Recovered' = 2; 'Added' = 3; 'Removed' = 4 }

    $comparison = foreach ($id in $allIds) {
        $b = $beforeById[$id]; $a = $afterById[$id]
        if ($b -and -not $a) {
            $change = 'Removed'; $ref = $b; $bState = $b.Online; $aState = '(gone)'
        } elseif ($a -and -not $b) {
            $change = 'Added';   $ref = $a; $bState = '(new)';   $aState = $a.Online
        } else {
            $ref = $a; $bState = $b.Online; $aState = $a.Online
            if ($bState -eq $aState) {
                if     ($aState -eq 'Offline') { $change = 'Still Down' }
                elseif ($aState -eq 'Online')  { $change = 'Unchanged (OK)' }
                else                           { $change = 'Unchanged (Unknown)' }
            } elseif ($bState -eq 'Online' -and $aState -eq 'Offline') {
                $change = 'NEWLY DOWN'
            } elseif ($bState -eq 'Offline' -and $aState -eq 'Online') {
                $change = 'Recovered'
            } else {
                $change = "$bState -> $aState"
            }
        }
        [pscustomobject]@{
            Change       = $change
            Camera       = $ref.Camera
            HardwareName = $ref.HardwareName
            RecorderName = $ref.RecorderName
            Before       = $bState
            After        = $aState
            Id           = $id
            SortKey      = if ($rank.ContainsKey($change)) { $rank[$change] } else { 9 }
        }
    }
    $comparison = @($comparison)

    $newlyDown = @($comparison | Where-Object Change -eq 'NEWLY DOWN')
    Write-Host ("`nBefore: {0} cameras | After: {1} cameras" -f $before.Count, $after.Count) -ForegroundColor Cyan
    Write-Host ("NEWLY DOWN: {0}   Recovered: {1}   Still Down: {2}" -f `
        $newlyDown.Count,
        @($comparison | Where-Object Change -eq 'Recovered').Count,
        @($comparison | Where-Object Change -eq 'Still Down').Count) -ForegroundColor Yellow

    if ($newlyDown.Count) {
        Write-Host "`nCameras that went DOWN after (fix these):" -ForegroundColor Red
        $newlyDown | ForEach-Object { Write-Host ("  {0}  ({1} / {2})" -f $_.Camera, $_.HardwareName, $_.RecorderName) }
    } else {
        Write-Host "`nNo cameras went down. " -ForegroundColor Green
    }

    $sorted = $comparison | Sort-Object SortKey, RecorderName, HardwareName, Camera | Select-Object Change, Camera, HardwareName, RecorderName, Before, After, Id
    $sorted | Out-GridView -Title "Camera health comparison (before -> after)"

    $answer = Read-Host "`nExport the comparison to CSV? (y/N)"
    if ($answer -match '^(y|yes)$') {
        $stamp   = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
        $default = Join-Path $env:USERPROFILE "Downloads\CameraHealth_Compare_$stamp.csv"
        $path = Read-Host "Save to (press Enter for $default)"
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
        $sorted | Export-Csv -Path $path -NoTypeInformation
        Write-Host "Exported to: $path" -ForegroundColor Green
    }
}
