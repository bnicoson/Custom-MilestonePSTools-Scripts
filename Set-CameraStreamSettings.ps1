# Set-CameraStreamSettings.ps1
# Bulk-apply stream settings (FPS, resolution, codec, compression, Axis Zipstream, etc.)
# AND motion detection settings to a grid-selected set of cameras.
#
# Flow: pick recording server -> grid-select cameras -> pick which settings to change from a
# combined Stream/Motion menu (Out-GridView) -> pick each value from that setting's VALID
# values -> preview -> confirm -> apply -> optional CSV log.
#
# Stream settings: valid values come from each camera's ValueTypeInfo, so illegal values
#   can't be chosen. The menu is built from the first AXIS camera in the selection (most of
#   the fleet is Axis); at apply time each stream value is re-resolved against ITS OWN driver,
#   so mixed models are handled - unsupported settings/values are skipped and logged.
# Motion settings: typed parameters on Set-VmsCameraMotion with fixed valid values.
#
# Stream changes target the primary recorded stream (falls back to the default live stream).

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Motion setting descriptors (Set-VmsCameraMotion params + their valid values) ---
$MotionSettings = @(
    [pscustomobject]@{ Name = 'Enabled';                  Label = 'Motion detection on/off';    Kind = 'Bool' }
    [pscustomobject]@{ Name = 'DetectionMethod';          Label = 'Detection method';           Kind = 'Choice'; Values = @('Normal','Optimized','Fast') }
    [pscustomobject]@{ Name = 'ManualSensitivityEnabled'; Label = 'Manual sensitivity on/off';   Kind = 'Bool' }
    [pscustomobject]@{ Name = 'ManualSensitivity';        Label = 'Manual sensitivity value';    Kind = 'Int';    Min = 0; Max = 300; Note = 'MC shows 0-100; PowerShell value is 3x that' }
    [pscustomobject]@{ Name = 'Threshold';                Label = 'Motion threshold';            Kind = 'Int';    Min = 0; Max = $null; Note = 'pixels that must change to trigger motion' }
    [pscustomobject]@{ Name = 'KeyframesOnly';            Label = 'Detect on keyframes only';    Kind = 'Bool' }
    [pscustomobject]@{ Name = 'ProcessTime';              Label = 'Process time (MJPEG only)';   Kind = 'Choice'; Values = @('Ms100','Ms250','Ms500','Ms750','Ms1000') }
    [pscustomobject]@{ Name = 'HardwareAccelerationMode'; Label = 'Hardware acceleration';       Kind = 'Choice'; Values = @('Automatic','Off') }
    [pscustomobject]@{ Name = 'GenerateMotionMetadata';   Label = 'Generate motion metadata';    Kind = 'Bool' }
)

# --- Helpers ---
function Get-CamStream {
    param($Camera)
    $st = $Camera | Get-VmsCameraStream -RecordingTrack Primary -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $st) { $st = $Camera | Get-VmsCameraStream -LiveDefault -ErrorAction SilentlyContinue | Select-Object -First 1 }
    return $st
}
function Test-HasKey {
    param($Table, [string]$Key)
    if ($null -eq $Table) { return $false }
    return ($Table.Keys -contains $Key)
}
function Get-PropSafe {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}
# Classify a stream setting: 'Enum' (fixed value list), 'Range' (numeric min/max), or 'Text'.
function Get-StreamKind {
    param($ValueTypeInfo, [string]$Key)
    if (-not (Test-HasKey $ValueTypeInfo $Key)) { return 'Text' }
    $names = @($ValueTypeInfo[$Key] | ForEach-Object { $_.Name })
    if ($names -contains 'MinValue' -or $names -contains 'MaxValue') { return 'Range' }
    return 'Enum'
}
# Prompt for an integer within an optional min/max; returns $null if blank/cancelled.
function Read-IntValue {
    param([string]$Label, $Min, $Max, [string]$Note, $Current)
    $hint = @()
    if ($null -ne $Min) { $hint += "min $Min" }
    if ($null -ne $Max) { $hint += "max $Max" }
    if ($Note)          { $hint += $Note }
    $hintText = if ($hint.Count) { " (" + ($hint -join '; ') + ")" } else { "" }
    while ($true) {
        $entry = Read-Host "Value for '$Label'$hintText [current $Current; blank = skip]"
        if ([string]::IsNullOrWhiteSpace($entry)) { return $null }
        $num = $entry -as [int]
        if ($null -eq $num) { Write-Host "  Not a whole number. Try again." -ForegroundColor Yellow; continue }
        if (($null -ne $Min -and $num -lt [int]$Min) -or ($null -ne $Max -and $num -gt [int]$Max)) {
            Write-Host "  Out of range. Try again." -ForegroundColor Yellow; continue
        }
        return $num
    }
}

# --- Pick one or more recording servers ---
$recorders = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select recording server(s) (Ctrl/Shift for multiple)" -OutputMode Multiple
if (-not $recorders) { Write-Warning "No recording server selected. Nothing to do."; return }
$serverCount = ($recorders | Measure-Object).Count
$serverLabel = if ($serverCount -eq 1) { $recorders.Name } else { "$serverCount servers" }

# --- Build camera rows, keeping the real camera object ---
Write-Host "Loading cameras on $serverLabel..." -ForegroundColor Cyan
$cameraRows = foreach ($rec in $recorders) {
    foreach ($hw in ($rec | Get-VmsHardware)) {
        foreach ($cam in ($hw | Get-VmsCamera -EnableFilter All)) {
            [pscustomobject]@{
                Camera = $cam; Name = $cam.Name; HardwareName = $hw.Name
                RecorderName = $rec.Name; Model = $hw.Model; Enabled = $cam.Enabled; Id = $cam.Id
            }
        }
    }
}
if (-not $cameraRows) { Write-Warning "No cameras found on $serverLabel."; return }

# --- Select cameras to configure ---
$picked = $cameraRows |
    Select-Object Name, RecorderName, HardwareName, Model, Enabled, Id |
    Sort-Object RecorderName, Name |
    Out-GridView -Title "Select cameras to configure (Ctrl/Shift for multiple) - $serverLabel" -OutputMode Multiple
if (-not $picked) { Write-Host "No cameras selected. No changes made." -ForegroundColor Red; return }

$byId = @{}
foreach ($row in $cameraRows) { $byId[$row.Id] = $row.Camera }
$targetCams = foreach ($p in $picked) { $byId[$p.Id] }

# --- Reference camera, preferring the first AXIS camera (most of the fleet is Axis) ---
$pickedAxisFirst = @($picked | Where-Object { $_.Model -match 'AXIS' }) + @($picked | Where-Object { $_.Model -notmatch 'AXIS' })
$refCam = $byId[$pickedAxisFirst[0].Id]
$refModel = $pickedAxisFirst[0].Model
if ($refModel -match 'AXIS') {
    Write-Host "Building settings menu from Axis camera: '$($refCam.Name)' ($refModel)" -ForegroundColor Cyan
} else {
    Write-Warning "No Axis camera in selection - building menu from '$($refCam.Name)' ($refModel) instead."
}

# Reference stream (first camera in Axis-first order that returns a stream)
$refStream = $null
foreach ($p in $pickedAxisFirst) { $refStream = Get-CamStream ($byId[$p.Id]); if ($refStream) { break } }
$refMotion = $refCam | Get-VmsCameraMotion -ErrorAction SilentlyContinue

# --- Build the combined Stream + Motion menu ---
$streamKinds = @{}   # setting name -> Enum/Range/Text
$menu = New-Object System.Collections.Generic.List[object]

if ($refStream) {
    $refSettings = $refStream.Settings
    $refVti      = $refStream.ValueTypeInfo
    foreach ($key in ($refSettings.Keys | Sort-Object)) {
        $kind = Get-StreamKind $refVti $key
        $streamKinds[$key] = $kind
        $type = if ($kind -eq 'Enum') { 'Choice' } elseif ($kind -eq 'Range') { 'Number' } else { 'Text' }
        $menu.Add([pscustomobject]@{ Category = 'Stream'; Setting = $key; Current = $refSettings[$key]; Type = $type })
    }
} else {
    Write-Warning "No readable stream on the selected cameras - only Motion settings will be offered."
}

foreach ($m in $MotionSettings) {
    $type = if ($m.Kind -eq 'Bool') { 'True/False' } elseif ($m.Kind -eq 'Choice') { 'Choice' } else { 'Number' }
    $menu.Add([pscustomobject]@{ Category = 'Motion'; Setting = $m.Label; Current = (Get-PropSafe $refMotion $m.Name); Type = $type })
}

if ($menu.Count -eq 0) { Write-Warning "Nothing to configure."; return }

$chosen = $menu |
    Out-GridView -Title "Select settings to change (from '$($refCam.Name)') - Ctrl/Shift for multiple" -OutputMode Multiple
if (-not $chosen) { Write-Host "No settings selected. No changes made." -ForegroundColor Red; return }

# --- Get a value for each chosen setting ---
$changes = New-Object System.Collections.Generic.List[object]
foreach ($cs in $chosen) {
    $key = $cs.Setting

    if ($cs.Category -eq 'Stream') {
        $kind = $streamKinds[$key]
        if ($kind -eq 'Enum') {
            $options = @($refVti[$key] | Select-Object Name, Value)
            if ($key -match 'Resolution') {
                $options = @([pscustomobject]@{ Name = '*** HIGHEST available (per camera) ***'; Value = '__MAX__' }) + $options
            }
            $pick = $options | Out-GridView -Title "Value for '$key'  (current: $($cs.Current))" -OutputMode Single
            if (-not $pick) { Write-Host "  Skipped '$key'." -ForegroundColor DarkGray; continue }
            if ($pick.Value -eq '__MAX__') {
                $changes.Add([pscustomobject]@{ Category = 'Stream'; Setting = $key; Kind = 'EnumMax'; Display = 'HIGHEST (per camera)'; Value = '__MAX__' })
            } else {
                $changes.Add([pscustomobject]@{ Category = 'Stream'; Setting = $key; Kind = 'Enum'; Display = $pick.Name; Value = $pick.Value })
            }
        }
        elseif ($kind -eq 'Range') {
            $min  = ($refVti[$key] | Where-Object Name -eq 'MinValue').Value
            $max  = ($refVti[$key] | Where-Object Name -eq 'MaxValue').Value
            $step = ($refVti[$key] | Where-Object Name -eq 'StepValue').Value
            $note = if ($step) { "step $step" } else { $null }
            $val  = Read-IntValue -Label $key -Min $min -Max $max -Note $note -Current $cs.Current
            if ($null -eq $val) { Write-Host "  Skipped '$key'." -ForegroundColor DarkGray; continue }
            $changes.Add([pscustomobject]@{ Category = 'Stream'; Setting = $key; Kind = 'Range'; Display = "$val"; Value = "$val" })
        }
        else {
            $entry = Read-Host "Value for '$key' (current $($cs.Current); blank = skip)"
            if ([string]::IsNullOrWhiteSpace($entry)) { Write-Host "  Skipped '$key'." -ForegroundColor DarkGray; continue }
            $changes.Add([pscustomobject]@{ Category = 'Stream'; Setting = $key; Kind = 'Text'; Display = $entry.Trim(); Value = $entry.Trim() })
        }
    }
    else {  # Motion  ($key is the friendly Label; map back to the real parameter name)
        $desc = $MotionSettings | Where-Object Label -eq $key | Select-Object -First 1
        if ($desc.Kind -eq 'Bool') {
            $pick = @([pscustomobject]@{ Choice = 'True' }, [pscustomobject]@{ Choice = 'False' }) |
                Out-GridView -Title "Value for '$key'  (current: $($cs.Current))" -OutputMode Single
            if (-not $pick) { Write-Host "  Skipped '$key'." -ForegroundColor DarkGray; continue }
            $changes.Add([pscustomobject]@{ Category = 'Motion'; Setting = $desc.Name; Kind = 'Bool'; Display = $pick.Choice; Value = [bool]::Parse($pick.Choice) })
        }
        elseif ($desc.Kind -eq 'Choice') {
            $pick = $desc.Values | ForEach-Object { [pscustomobject]@{ Value = $_ } } |
                Out-GridView -Title "Value for '$key'  (current: $($cs.Current))" -OutputMode Single
            if (-not $pick) { Write-Host "  Skipped '$key'." -ForegroundColor DarkGray; continue }
            $changes.Add([pscustomobject]@{ Category = 'Motion'; Setting = $desc.Name; Kind = 'Choice'; Display = $pick.Value; Value = $pick.Value })
        }
        else {  # Int
            $val = Read-IntValue -Label $key -Min $desc.Min -Max $desc.Max -Note $desc.Note -Current $cs.Current
            if ($null -eq $val) { Write-Host "  Skipped '$key'." -ForegroundColor DarkGray; continue }
            $changes.Add([pscustomobject]@{ Category = 'Motion'; Setting = $desc.Name; Kind = 'Int'; Display = "$val"; Value = [int]$val })
        }
    }
}
if ($changes.Count -eq 0) { Write-Host "No values chosen. No changes made." -ForegroundColor Red; return }

# --- Preview ---
Write-Host "`nPlanned changes for $($targetCams.Count) camera(s):" -ForegroundColor Cyan
$changes | ForEach-Object { Write-Host ("  [{0}] {1}  ->  {2}" -f $_.Category, $_.Setting, $_.Display) -ForegroundColor White }

$confirm = Read-Host "`nApply to $($targetCams.Count) camera(s) on $serverLabel? (yes/no)"
if ($confirm -ne 'yes') { Write-Host "Cancelled. No changes made." -ForegroundColor Red; return }

$streamChanges = @($changes | Where-Object Category -eq 'Stream')
$motionChanges = @($changes | Where-Object Category -eq 'Motion')

# --- Apply ---
$log = New-Object System.Collections.Generic.List[object]
foreach ($cam in $targetCams) {

    # ---- Stream settings (re-resolve each value against this camera's own driver) ----
    if ($streamChanges.Count) {
        $stream = Get-CamStream $cam
        if (-not $stream) {
            $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = '(all)'; Old = ''; New = ''; Result = 'No stream' })
        } else {
            $curSettings = $stream.Settings
            $curVti      = $stream.ValueTypeInfo
            $apply       = @{}
            $pending     = @()
            foreach ($chg in $streamChanges) {
                $key = $chg.Setting
                if (-not (Test-HasKey $curSettings $key)) {
                    $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = $key; Old = ''; New = $chg.Display; Result = 'Setting not on camera' }); continue
                }
                $old = $curSettings[$key]; $newDisplay = $chg.Display
                if ($chg.Kind -eq 'Enum') {
                    $match = @($curVti[$key] | Where-Object { $_.Name -eq $chg.Display })
                    if ($match.Count -eq 0) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = $key; Old = $old; New = $chg.Display; Result = 'Value not valid on camera' }); continue }
                    $apply[$key] = $match[0].Value
                } elseif ($chg.Kind -eq 'EnumMax') {
                    if (-not (Test-HasKey $curVti $key)) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = $key; Old = $old; New = 'HIGHEST'; Result = 'No resolution list on camera' }); continue }
                    $best = $null; $bestPixels = -1
                    foreach ($e in @($curVti[$key])) {
                        if ($e.Name -match '(\d+)\s*[xX]\s*(\d+)') {
                            $px = [int]$Matches[1] * [int]$Matches[2]
                            if ($px -gt $bestPixels) { $bestPixels = $px; $best = $e }
                        }
                    }
                    if (-not $best) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = $key; Old = $old; New = 'HIGHEST'; Result = 'Could not parse a WxH resolution' }); continue }
                    $apply[$key] = $best.Value; $newDisplay = $best.Name
                } else {
                    $apply[$key] = $chg.Value
                }
                $pending += [pscustomobject]@{ Setting = $key; Old = $old; New = $newDisplay }
            }
            if ($apply.Count) {
                try {
                    $stream | Set-VmsCameraStream -Settings $apply -ErrorAction Stop | Out-Null
                    foreach ($p in $pending) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = $p.Setting; Old = $p.Old; New = $p.New; Result = 'Applied' }) }
                    Write-Host "Stream updated: $($cam.Name)" -ForegroundColor Green
                } catch {
                    foreach ($p in $pending) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Stream'; Setting = $p.Setting; Old = $p.Old; New = $p.New; Result = "Failed: $($_.Exception.Message)" }) }
                    Write-Warning "Stream FAILED on $($cam.Name): $($_.Exception.Message)"
                }
            }
        }
    }

    # ---- Motion settings ----
    if ($motionChanges.Count) {
        $camMotion   = $cam | Get-VmsCameraMotion -ErrorAction SilentlyContinue
        $motionSplat = @{}
        $mpending    = @()
        foreach ($mc in $motionChanges) {
            $old = Get-PropSafe $camMotion $mc.Setting
            $motionSplat[$mc.Setting] = $mc.Value
            $mpending += [pscustomobject]@{ Setting = $mc.Setting; Old = $old; New = $mc.Display }
        }
        try {
            $cam | Set-VmsCameraMotion @motionSplat -ErrorAction Stop | Out-Null
            foreach ($p in $mpending) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Motion'; Setting = $p.Setting; Old = $p.Old; New = $p.New; Result = 'Applied' }) }
            Write-Host "Motion updated: $($cam.Name)" -ForegroundColor Green
        } catch {
            foreach ($p in $mpending) { $log.Add([pscustomobject]@{ Camera = $cam.Name; Category = 'Motion'; Setting = $p.Setting; Old = $p.Old; New = $p.New; Result = "Failed: $($_.Exception.Message)" }) }
            Write-Warning "Motion FAILED on $($cam.Name): $($_.Exception.Message)"
        }
    }
}

$applied = @($log | Where-Object Result -eq 'Applied').Count
Write-Host "`nDone. $applied setting change(s) applied across $($targetCams.Count) camera(s)." -ForegroundColor Green

# --- Change log + optional CSV export ---
$log | Out-GridView -Title "Change log - $serverLabel"
$answer = Read-Host "Export the change log to CSV? (y/N)"
if ($answer -match '^(y|yes)$') {
    $default = Join-Path $env:USERPROFILE "Downloads\CameraSettingsLog_$($serverLabel -replace '[^\w\-]', '_').csv"
    $path = Read-Host "Save to (press Enter for $default)"
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
    $log | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Exported to: $path" -ForegroundColor Green
}
