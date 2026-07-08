# Get-CameraStorageByServer.ps1
# Pick a recording server, then show recording storage used per camera on that server.

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Pick one or more recording servers ---
$recorders = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select recording server(s) (Ctrl/Shift for multiple)" -OutputMode Multiple

if (-not $recorders) {
    Write-Warning "No recording server selected. Nothing to do."
    return
}

$serverCount = ($recorders | Measure-Object).Count
$serverLabel = if ($serverCount -eq 1) { $recorders.Name } else { "$serverCount servers" }
Write-Host "Building camera report for $serverLabel ..." -ForegroundColor Cyan

# Scope the report to the selected server(s), and include retention info so
# UsedSpaceInGB / MediaDatabase timestamps / ActualRetentionDays are populated.
# (Per-camera "not supported" / multi-streaming lines are harmless per-device warnings.)
$report = Get-VmsCameraReport -RecordingServer $recorders -IncludeRetentionInfo -Verbose

if (-not $report) {
    Write-Warning "No cameras found on $serverLabel."
    return
}

# UsedSpaceInGB can be the string "Unavailable" on some cameras; sum only numeric values.
$totalGB = ($report | ForEach-Object { $_.UsedSpaceInGB -as [double] } |
    Where-Object { $_ -ne $null } | Measure-Object -Sum).Sum
Write-Host ("Found {0} camera(s) on {1} using {2:N1} GB total.`n" -f ($report | Measure-Object).Count, $serverLabel, $totalGB) -ForegroundColor Yellow

$display = $report |
    Select-Object `
        Name,
        RecorderName,
        HardwareName,
        DriverNumber,
        Driver,
        Enabled,
        RecordingEnabled,
        @{n='UsedSpaceGB'; e={ $n = $_.UsedSpaceInGB -as [double]; if ($null -ne $n) { [math]::Round($n, 1) } else { $_.UsedSpaceInGB } }},
        RecordingStorageName,
        ActualRetentionDays,
        ExpectedRetentionDays,
        MediaDatabaseBegin,
        MediaDatabaseEnd,
        RecordingPath |
    Sort-Object @{ e={ $_.UsedSpaceGB -as [double] } } -Descending

# Show the interactive grid
$display | Out-GridView -Title "Storage used per camera on $serverLabel  (total $([math]::Round($totalGB,1)) GB)"

# Offer a CSV export
$answer = Read-Host "Export this to CSV as well? (y/N)"
if ($answer -match '^(y|yes)$') {
    $default = Join-Path $env:USERPROFILE "Downloads\CameraStorage_$($serverLabel -replace '[^\w\-]', '_').csv"
    $path = Read-Host "Save to (press Enter for $default)"
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
    $display | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Exported to: $path" -ForegroundColor Green
}
