# Get-CameraSettingsReport.ps1
# Pick one or more recording servers, then report per-camera stream + motion settings:
# codec, resolution, FPS, bitrate control, compression/quality, GOP, Axis Zipstream, and
# motion detection (enabled/threshold/sensitivity). View in GridView, optional CSV export.
#
# NOTE: Stream setting keys vary widely by camera make/model/driver. Common keys are mapped
# to named columns; the full key=value set is preserved in the AllStreamSettings column so
# nothing driver-specific is lost. Reports the primary recorded stream (falls back to the
# default live stream) - that's the stream that drives storage and where Zipstream lives.

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Helpers ---
# Read a value from a stream Settings hashtable, trying several possible key names.
function Get-StreamValue {
    param($Settings, [string[]]$Keys)
    if ($null -eq $Settings) { return $null }
    foreach ($k in $Keys) {
        if ($Settings.ContainsKey($k)) { return $Settings[$k] }
    }
    return $null
}
# Read a property off an object only if it exists (settings/props vary by driver + version).
function Get-PropSafe {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

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
Write-Host "Gathering camera settings for $serverLabel (this can take a while on large systems)..." -ForegroundColor Cyan

$rows = foreach ($rec in $recorders) {
    foreach ($hw in ($rec | Get-VmsHardware)) {
        foreach ($cam in ($hw | Get-VmsCamera -EnableFilter All)) {

            # Recorded (primary) stream preferred; fall back to default live stream.
            $stream = $cam | Get-VmsCameraStream -RecordingTrack Primary -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $stream) {
                $stream = $cam | Get-VmsCameraStream -LiveDefault -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            $s = if ($stream) { $stream.Settings } else { $null }

            # Motion detection settings
            $motion = $cam | Get-VmsCameraMotion -ErrorAction SilentlyContinue

            [pscustomobject]@{
                RecorderName      = $rec.Name
                HardwareName      = $hw.Name
                Model             = $hw.Model
                Camera            = $cam.Name
                Enabled           = $cam.Enabled
                Stream            = if ($stream) { $stream.DisplayName } else { $null }
                Codec             = Get-StreamValue $s 'Codec'
                Resolution        = Get-StreamValue $s @('Resolution','StreamResolution')
                FPS               = Get-StreamValue $s @('FPS','Framerate','FrameRate')
                ControlMode       = Get-StreamValue $s @('ControlMode','BitrateControlMode')
                TargetBitrate     = Get-StreamValue $s @('TargetBitrate','Bitrate')
                MaxBitrate        = Get-StreamValue $s 'MaxBitrate'
                Compression       = Get-StreamValue $s 'Compression'
                Quality           = Get-StreamValue $s 'Quality'
                GOPMode           = Get-StreamValue $s @('MaxGOPMode','GOPMode')
                GOPSize           = Get-StreamValue $s @('MaxGOPSize','GOPSize')
                ZipStrength       = Get-StreamValue $s 'ZStrength'      # Axis Zipstream strength
                ZipGOPMode        = Get-StreamValue $s 'ZGopMode'       # Axis Zipstream dynamic GOP
                ZipFpsMode        = Get-StreamValue $s 'ZFpsMode'       # Axis Zipstream dynamic FPS
                MotionEnabled     = Get-PropSafe $motion 'Enabled'
                MotionThreshold   = Get-PropSafe $motion 'Threshold'
                MotionSensitivity = Get-PropSafe $motion 'ManualSensitivity'
                MotionKeyframesOnly = Get-PropSafe $motion 'KeyframesOnly'
                MotionHWAccel     = Get-PropSafe $motion 'HardwareAccelerationMode'
                AllStreamSettings = if ($s) { (($s.Keys | Sort-Object | ForEach-Object { "$_=$($s[$_])" }) -join '; ') } else { $null }
            }
        }
    }
}

if (-not $rows) {
    Write-Warning "No cameras found on $serverLabel."
    return
}

Write-Host ("Gathered settings for {0} camera(s) on {1}.`n" -f ($rows | Measure-Object).Count, $serverLabel) -ForegroundColor Yellow

$sorted = $rows | Sort-Object RecorderName, HardwareName, Camera

# Show the interactive grid
$sorted | Out-GridView -Title "Camera settings on $serverLabel"

# Offer a CSV export
$answer = Read-Host "Export this to CSV as well? (y/N)"
if ($answer -match '^(y|yes)$') {
    $default = Join-Path $env:USERPROFILE "Downloads\CameraSettings_$($serverLabel -replace '[^\w\-]', '_').csv"
    $path = Read-Host "Save to (press Enter for $default)"
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
    $sorted | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Exported to: $path" -ForegroundColor Green
}
