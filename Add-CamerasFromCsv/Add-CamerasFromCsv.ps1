<#
    Add-CamerasFromCsv.ps1
    ----------------------------------------------------------------------------
    Batch-adds cameras to Milestone XProtect from a CSV, then applies a common set
    of post-add settings to EVERY lens (camera channel) added, enables metadata,
    and produces a documentation report.

    HYBRID DESIGN:
      * The ADD step uses Milestone's own Import-VmsHardware cmdlet (native Axis
        driver-group scan, multi-channel, multi-credential, per-row recording server).
      * A before/after hardware diff identifies exactly what THIS run added, so the
        configuration + report only touch the new cameras.
      * The CONFIGURATION + REPORT layer (metadata enable, prompt-once Zipstream /
        compression / motion threshold on every lens, 360 flagging, firmware report)
        is done here, because Import-VmsHardware only adds - it has no interactive
        settings path (detailed stream config via Import only works through the
        Export-VmsHardware .xlsx round-trip).

    CSV COLUMNS (header row required; matching is case-insensitive):
        IP               (required)  e.g. 10.10.10.50
        Name             (optional)  e.g. Parking Lot South East
                                     -> hardware is named "IP - Name" (e.g. "10.10.10.50 - Parking Lot South East")
                                     -> if blank, Milestone's default name is used
        Username         (optional)  camera admin user; blank -> falls back to a credential you enter at runtime
        Password         (optional)  camera admin password (PLAIN TEXT - see note below)
        Driver           (optional)  Milestone driver NUMBER (e.g. 806) or a driver NAME.
                                     -> blank OR unmatched name -> Axis driver-group scan (97% of our cameras);
                                        non-Axis / offline rows are reported as failures.
        Port             (optional)  HTTP port; blank -> 80 (embedded into the Address URI)
        RecordingServer  (optional)  recording server NAME; blank/unmatched -> you pick one at runtime (reused for all blanks)
        FPS              (optional)  frame rate applied to every lens; blank -> 8
        MotionDetection  (optional)  Yes/No - enable motion detection on every lens; blank -> Yes
        MotionThreshold  (optional)  motion threshold (raw pixel count, NOT the 0-100 Mgmt Client number); blank -> 200
        DeviceGroup      (optional)  extra camera device-group path(s), e.g. /Site A (semicolon-delimited for
                                     several). Added ON TOP of Import's "/Imported from CSV"; groups are created if missing.

    FPS and motion are applied automatically (with the defaults above) to every lens added; put a
    value in the column to override per camera. Compression and Axis Zipstream are still asked for
    once at runtime and applied to every lens (leave a prompt blank to skip that one).

    ALL camera channels on each added hardware are enabled, so multisensor lenses are never left
    disabled. On single-sensor Axis cameras this also enables view-area channels - the 360/multi-view
    flag and the end-of-run reminder call these out so you can disable any you don't want recording.

    Every camera stays in Import's "/Imported from CSV" group; anything in the DeviceGroup column is
    added on top of that (not replacing it), and the group is created if it doesn't exist.

    SECURITY NOTE: passwords are plain text in the CSV, and this script writes an
    import CSV (also plain text) that is KEPT after the run - its path is printed at
    the end. Keep both files somewhere safe and delete them when you're done.

    EVIDENCE (MilestonePSTools docs this script is built on):
        Import-VmsHardware   - CSV add; DriverGroup 'Axis' scan; per-row RecordingServer; multi-credential
        Get-Metadata         - enable the metadata device (per Enable-MetaData.ps1)
        Set-VmsCameraStream  - compression / Axis Zipstream via the stream Settings hashtable
        Set-VmsCameraMotion  - motion detection threshold
        Get-VmsCameraReport  - firmware / MAC / config for the documentation report
#>

[CmdletBinding()]
param(
    [string]$CsvPath,
    [string]$ReportPath,
    [switch]$SkipEnableAllChannels,  # testing aid: leave channels exactly as Import set them (don't force-enable)
    [string]$ImportGroupPath = '/Imported from CSV'  # the folder every camera is guaranteed to join
)

# MilestonePSTools requires Windows PowerShell 5.1 (.NET Framework / WCF). It will NOT
# load under PowerShell 7+ (pwsh / .NET Core) - it fails on a System.ServiceModel type load.
if ($PSVersionTable.PSEdition -eq 'Core') {
    throw "Run this in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh). MilestonePSTools requires .NET Framework."
}

# --- Import module ---
Import-Module MilestonePSTools -ErrorAction Stop

# --- Connect via dialog (lets user pick server) ---
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# ============================================================================
#  Helpers
# ============================================================================

# Read a field off a CSV row, trying several header spellings. Blank -> $null.
function Get-Field {
    param($Row, [string[]]$Names)
    foreach ($n in $Names) {
        if ($Row.PSObject.Properties.Match($n).Count -gt 0) {
            $val = $Row.$n
            if ($null -ne $val -and -not [string]::IsNullOrWhiteSpace([string]$val)) {
                return ([string]$val).Trim()
            }
        }
    }
    return $null
}

# Read a property off an object only if it exists (report columns vary by version).
function Get-PropSafe {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        if ($Object.PSObject.Properties.Match($n).Count -gt 0) {
            $v = $Object.$n
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return $v }
        }
    }
    return $null
}

# Read a value from a stream Settings hashtable, trying several key names.
function Get-StreamValue {
    param($Settings, [string[]]$Keys)
    if ($null -eq $Settings) { return $null }
    foreach ($k in $Keys) { if ($Settings.ContainsKey($k)) { return $Settings[$k] } }
    return $null
}

# Extract the host (IP) from a Hardware.Address like "http://10.10.10.50/".
function Get-HwHost {
    param($Hw)
    try { return ([uri]([string]$Hw.Address)).Host } catch { return [string]$Hw.Address }
}

# ============================================================================
#  Load the CSV
# ============================================================================
if ([string]::IsNullOrWhiteSpace($CsvPath)) { $CsvPath = Read-Host "Path to the camera CSV" }
if (-not (Test-Path -LiteralPath $CsvPath)) { Write-Warning "CSV not found: $CsvPath"; return }

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) { Write-Warning "CSV is empty: $CsvPath"; return }
Write-Host "Loaded $($rows.Count) row(s) from $CsvPath" -ForegroundColor Cyan

# ============================================================================
#  Recording servers + driver-number lookup (cached per recorder)
# ============================================================================
$allRecorders = @(Get-VmsRecordingServer)
if ($allRecorders.Count -eq 0) { Write-Warning "No recording servers found."; return }

$driverCache = @{}
function Get-Drivers {
    param($Recorder)
    if (-not $driverCache.ContainsKey($Recorder.Id)) { $driverCache[$Recorder.Id] = @($Recorder | Get-VmsHardwareDriver) }
    return $driverCache[$Recorder.Id]
}

# Blank/unmatched RecordingServer rows are assigned from a "fallback pool" chosen once at
# runtime. Pick multiple recorders at the prompt and blank rows are split evenly (round-robin).
$fallbackPool  = $null
$fallbackIndex = 0
function Resolve-Recorder {
    param([string]$Name)
    if ($Name) {
        $match = $allRecorders | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if ($match) { return $match }
        Write-Warning "Recording server '$Name' not found - it will be assigned from the fallback pool."
    }
    if ($null -eq $script:fallbackPool) {
        if ($allRecorders.Count -eq 1) {
            # Only one recording server on the site - no point prompting.
            $script:fallbackPool = @($allRecorders[0])
            Write-Host ("Only one recording server ('{0}') - using it for blank/unknown rows." -f $allRecorders[0].Name) -ForegroundColor DarkGray
        } else {
            $picked = $allRecorders | Sort-Object Name |
                Out-GridView -Title "Pick one or more recording servers for blank/unknown rows (pick multiple to split evenly, round-robin)" -OutputMode Multiple
            $script:fallbackPool = @($picked)
            if ($script:fallbackPool.Count -eq 0) { throw "No fallback recording server selected - cannot continue." }
            if ($script:fallbackPool.Count -eq 1) {
                Write-Host ("Blank/unknown rows -> {0}." -f $script:fallbackPool[0].Name) -ForegroundColor DarkGray
            } else {
                Write-Host ("Blank/unknown rows split round-robin across: {0}" -f (($script:fallbackPool | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
            }
        }
    }
    # Round-robin assignment for an even split across the chosen recorders.
    $rec = $script:fallbackPool[$script:fallbackIndex % $script:fallbackPool.Count]
    $script:fallbackIndex++
    return $rec
}

# ============================================================================
#  Normalize every row: resolve recorder, build address, decide driver
# ============================================================================
$plan = New-Object System.Collections.Generic.List[object]
foreach ($row in $rows) {
    $ip = Get-Field $row 'IP','IPAddress','Address'
    if (-not $ip) { Write-Warning "Row skipped - missing IP."; continue }

    $name = Get-Field $row 'Name','CameraName'
    $user = Get-Field $row 'Username','User'
    $pass = Get-Field $row 'Password','Pass'
    $drv  = Get-Field $row 'Driver','DriverNumber'
    $port = Get-Field $row 'Port'
    $recName = Get-Field $row 'RecordingServer','Recorder','Server'

    # Config settings (applied later to every lens on this hardware) with defaults.
    $fps = Get-Field $row 'FPS','FrameRate','Framerate'
    if (-not $fps) { $fps = '8' }
    $mdRaw = Get-Field $row 'MotionDetection','Motion'
    $motionOn = -not ($mdRaw -match '^(n|no|false|0|off|disabled?)$')   # blank/unknown -> enabled
    $thr = Get-Field $row 'MotionThreshold','Threshold'
    if ($thr -match '^\d+$') { $motionThr = [int]$thr } else { $motionThr = 200 }

    # Extra device group(s) to add the camera to, on top of Import's "/Imported from CSV".
    # Semicolon-delimited paths; a leading "/" is added if missing.
    $grpRaw = Get-Field $row 'DeviceGroup','DeviceGroups','Group'
    $groups = @()
    if ($grpRaw) {
        $groups = @($grpRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
                    ForEach-Object { if ($_ -match '^/') { $_ } else { '/' + $_ } })
    }

    $rec = Resolve-Recorder $recName

    # Address: bare IP when no port; URI with port otherwise (port isn't a column in the import schema).
    if ($port) { $addr = ("http://{0}:{1}" -f $ip, $port) } else { $addr = $ip }

    # Driver: number -> DriverNumber; name -> resolve to number; blank/unmatched -> Axis group scan.
    $driverNumber = ''
    $driverGroup  = ''
    if ($drv) {
        if ($drv -match '^\d+$') {
            $driverNumber = $drv
        } else {
            $found = Get-Drivers $rec | Where-Object { $_.Name -eq $drv } | Select-Object -First 1
            if (-not $found) { $found = Get-Drivers $rec | Where-Object { $_.Name -like "*$drv*" } | Select-Object -First 1 }
            if ($found) { $driverNumber = [string]$found.Number }
            else { Write-Warning ("Driver '{0}' not matched for {1} - will Axis-scan instead." -f $drv, $ip); $driverGroup = 'Axis' }
        }
    } else {
        $driverGroup = 'Axis'
    }

    $hwName = ''
    if ($name) { $hwName = ("{0} - {1}" -f $ip, $name) }

    $plan.Add([pscustomobject]@{
        IP = $ip; Name = $name; HwName = $hwName; User = $user; Pass = $pass
        Address = $addr; DriverNumber = $driverNumber; DriverGroup = $driverGroup
        Recorder = $rec; RecorderName = $rec.Name
        FPS = $fps; MotionOn = $motionOn; MotionThreshold = $motionThr
        DeviceGroups = $groups
    })
}
if ($plan.Count -eq 0) { Write-Warning "No usable rows."; return }

# Fallback credential for rows missing user/pass.
$fallbackCred = $null
if ($plan | Where-Object { -not $_.User -or -not $_.Pass }) {
    Write-Host "Some rows are missing Username/Password - enter a credential to use for those rows." -ForegroundColor Yellow
    $fallbackCred = Get-Credential -Message "Fallback camera credential (used when the CSV leaves user/pass blank)"
}

# ============================================================================
#  Prompt ONCE for the uniform settings (Zipstream + compression).
#  FPS and motion come from the CSV (with defaults) - no prompt needed.
# ============================================================================
Write-Host "`n=== Uniform settings (applied to EVERY lens that gets added) ===" -ForegroundColor Cyan
Write-Host "FPS + motion come from the CSV (defaults: 8 fps, motion on, threshold 200)."
Write-Host "Leave a prompt blank to skip that setting.`n"

$doZip = (Read-Host "Apply Axis Zipstream? (y/N)") -match '^(y|yes)$'
$zStrength = $null; $zGop = $null; $zFps = $null
if ($doZip) {
    Write-Host "  (Zipstream keys only exist on Axis streams; non-Axis lenses are skipped automatically.)" -ForegroundColor DarkGray
    $zStrength = Read-Host "  Zipstream strength (e.g. Off / Low / Medium / High - depends on model; Enter to skip)"
    $zGop      = Read-Host "  Zipstream dynamic GOP mode (e.g. Dynamic / Fixed; Enter to skip)"
    $zFps      = Read-Host "  Zipstream dynamic FPS mode (e.g. Dynamic / Fixed; Enter to skip)"
    if (-not $zStrength) { $zStrength = $null }
    if (-not $zGop)      { $zGop = $null }
    if (-not $zFps)      { $zFps = $null }
}

$doComp = (Read-Host "Apply compression/quality value? (y/N)") -match '^(y|yes)$'
$compVal = $null
if ($doComp) { $compVal = Read-Host "  Compression value (numeric, e.g. 30)"; if (-not $compVal) { $doComp = $false } }

# Fast lookup of per-camera config by host (IP), used during the configure phase.
$cfgByHost = @{}
foreach ($p in $plan) { $cfgByHost[$p.IP] = $p }

# ============================================================================
#  Build the temporary Import-VmsHardware CSV
# ============================================================================
$tempCsv = Join-Path $env:TEMP ("vmsimport_{0}.csv" -f (Get-Date).ToString('yyyyMMdd_HHmmss'))
$importRows = foreach ($p in $plan) {
    [pscustomobject]@{
        DeviceType      = 'Camera'
        HardwareName    = $p.HwName          # names the HARDWARE ("IP - Name"); metadata name follows from this
        Name            = $p.HwName          # names the CAMERA device the same; blank -> Milestone default
        Address         = $p.Address
        UserName        = $p.User
        Password        = $p.Pass
        DriverNumber    = $p.DriverNumber
        DriverGroup     = $p.DriverGroup     # 'Axis' when number unknown
        RecordingServer = $p.RecorderName
    }
}
$importRows | Export-Csv -Path $tempCsv -NoTypeInformation
Write-Host "Prepared import file for $($plan.Count) camera(s): $tempCsv" -ForegroundColor Cyan

# ============================================================================
#  Snapshot -> Import -> diff (so we know exactly what got added)
# ============================================================================
$involved = @($plan | Group-Object { $_.Recorder.Id } | ForEach-Object { $_.Group[0].Recorder })

$beforeIds   = New-Object 'System.Collections.Generic.HashSet[string]'
$beforeHosts = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($r in $involved) {
    foreach ($h in ($r | Get-VmsHardware)) {
        [void]$beforeIds.Add([string]$h.Id)
        [void]$beforeHosts.Add((Get-HwHost $h))
    }
}

$addedHw = New-Object System.Collections.Generic.List[object]
Write-Host "`nRunning Import-VmsHardware..." -ForegroundColor Cyan
$importSplat = @{ Path = $tempCsv }
if ($fallbackCred) { $importSplat['Credential'] = @($fallbackCred) }
$importResult = @()
try { $importResult = @(Import-VmsHardware @importSplat) }
catch { Write-Warning "Import-VmsHardware error: $($_.Exception.Message)" }
foreach ($ir in $importResult) {
    Write-Host ("  Row {0}  {1}  ->  {2}" -f (Get-PropSafe $ir 'Row'), (Get-PropSafe $ir 'Address'), (Get-PropSafe $ir 'Result'))
}

# Re-scan involved recorders; anything whose Id wasn't there before is new.
# Keep each new hardware paired with the recorder it landed on. (Runs even if the
# import partially failed, so we still pick up whatever did get added.)
foreach ($r in $involved) {
    foreach ($h in ($r | Get-VmsHardware)) {
        if (-not $beforeIds.Contains([string]$h.Id)) { $addedHw.Add([pscustomobject]@{ Hardware = $h; Recorder = $r }) }
    }
}

# Map added hardware back to plan rows (by host) for names, and compute per-row status.
$addedHosts = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $addedHw) { [void]$addedHosts.Add((Get-HwHost $e.Hardware)) }

$rowStatus = foreach ($p in $plan) {
    if ($addedHosts.Contains($p.IP))      { $st = 'Added' }
    elseif ($beforeHosts.Contains($p.IP)) { $st = 'AlreadyExisted' }
    else                                  { $st = 'Failed' }
    [pscustomobject]@{ IP=$p.IP; Name=$p.Name; Recorder=$p.RecorderName; Driver=$(if($p.DriverNumber){"#$($p.DriverNumber)"}else{'Axis scan'}); Status=$st }
}

if ($addedHw.Count -eq 0) {
    Write-Warning "Import-VmsHardware added no new hardware. Nothing to configure."
    $rowStatus | Format-Table -AutoSize
    return
}

# ============================================================================
#  Configure every added camera: metadata, stream settings, motion. Flag 360s.
# ============================================================================
$fisheyeKeywords = '360|fisheye|panoram|panomorph|multisensor|multi-sensor|multidirectional|multi-directional'
$reportRows = New-Object System.Collections.Generic.List[object]

Write-Host "`n=== Configuring $($addedHw.Count) added hardware device(s) ===" -ForegroundColor Cyan

foreach ($entry in $addedHw) {
    $hw  = $entry.Hardware
    $rec = $entry.Recorder
    $cfg = $cfgByHost[(Get-HwHost $hw)]   # per-camera FPS / motion settings from the CSV

    # --- Name the hardware "IP - Name" (Import sets the camera name; this sets the hardware) ---
    if ($cfg -and $cfg.HwName -and $hw.Name -ne $cfg.HwName) {
        try { $hw.Name = $cfg.HwName; $hw.Save() }
        catch { Write-Warning ("  {0}: hardware rename failed - {1}" -f (Get-HwHost $hw), $_.Exception.Message) }
    }

    # --- Enable ALL camera channels so multisensor lenses aren't left disabled.
    #     This also enables Axis view-area channels on single-sensor cams; the 360/multi-view
    #     flag and the end-of-run reminder tell you to review/disable any you don't want.
    #     Pass -SkipEnableAllChannels to leave channels exactly as Import set them (for testing). ---
    if (-not $SkipEnableAllChannels) {
        $enabledNow = 0
        foreach ($c in ($hw | Get-VmsCamera -EnableFilter All)) {
            if (-not $c.Enabled) {
                try { $c.Enabled = $true; $c.Save(); $enabledNow++ }
                catch { Write-Warning ("  {0}: could not enable channel '{1}' - {2}" -f $hw.Name, $c.Name, $_.Exception.Message) }
            }
        }
        if ($enabledNow -gt 0) { Write-Host ("  Enabled {0} additional channel(s) on {1}." -f $enabledNow, $hw.Name) -ForegroundColor DarkGray }
    } else {
        Write-Host ("  -SkipEnableAllChannels: leaving channels as Import set them on {0}." -f $hw.Name) -ForegroundColor DarkGray
    }

    # --- Enable + name the metadata device(s) (EnableFilter All so we catch disabled ones) ---
    $metaEnabled = $false
    try {
        $mdIndex = 0
        foreach ($md in (Get-VmsMetadata -Hardware $hw -EnableFilter All)) {
            $mdIndex++
            if (-not $md.Enabled) { Set-VmsMetadata -InputObject $md -Enabled $true | Out-Null }
            if ($cfg -and $cfg.HwName) {
                $mdName = "{0} - Metadata {1}" -f $cfg.HwName, $mdIndex
                if ($md.Name -ne $mdName) { Set-VmsMetadata -InputObject $md -Name $mdName | Out-Null }
            }
            $metaEnabled = $true
        }
    } catch { Write-Warning ("  {0}: metadata enable/name failed - {1}" -f $hw.Name, $_.Exception.Message) }

    # --- 360 / multi-view flag (heuristic - review, not auto-changed) ---
    # Count only ENABLED channels: Axis cameras expose extra (disabled) view-area channels
    # on ordinary single-sensor models, which would otherwise false-flag every one of them.
    $channelCount  = @($hw | Get-VmsCamera).Count                    # enabled channels
    $totalChannels = @($hw | Get-VmsCamera -EnableFilter All).Count  # all channels (incl. disabled view areas / sensors)
    $is360 = $false; $flagReason = ''
    if ($hw.Model -and $hw.Model -match $fisheyeKeywords) { $is360 = $true; $flagReason = 'model name keyword' }
    elseif ($channelCount -gt 1) { $is360 = $true; $flagReason = ("{0} enabled channels" -f $channelCount) }
    if ($is360) { Write-Host ("  FLAG: {0} looks like a 360/multi-view camera ({1}) - review extra views/recording." -f $hw.Name, $flagReason) -ForegroundColor Magenta }
    # Surface any hardware that has more channels than are enabled - could be a multisensor with sensors left disabled.
    if ($totalChannels -gt $channelCount) {
        Write-Host ("  NOTE: {0} has {1} channel(s), only {2} enabled - confirm whether disabled channel(s) are real sensors that should record." -f $hw.Name, $totalChannels, $channelCount) -ForegroundColor DarkYellow
    }

    # --- Resolve device groups once (create if missing). EVERY camera joins the import folder
    #     ($ImportGroupPath) plus any DeviceGroup paths from the CSV - added on top, not replacing. ---
    $groupPaths = @($ImportGroupPath)
    if ($cfg -and $cfg.DeviceGroups) { $groupPaths += $cfg.DeviceGroups }
    $groupPaths = @($groupPaths | Select-Object -Unique)
    $resolvedGroups = @()
    foreach ($path in $groupPaths) {
        try {
            $g = Get-VmsDeviceGroup -Path $path -Type Camera -ErrorAction SilentlyContinue
            if (-not $g) { $g = New-VmsDeviceGroup -Path $path -Type Camera; Write-Host ("  Created device group {0}" -f $path) -ForegroundColor DarkGray }
            if ($g) { $resolvedGroups += [pscustomobject]@{ Group = $g; Path = $path } }
        } catch { Write-Warning ("  device group '{0}' failed - {1}" -f $path, $_.Exception.Message) }
    }

    # --- Name every enabled camera. Single channel -> "IP - Name"; multi-channel -> "IP - Name - Camera N".
    #     Import only names channel 0, so extra sensors/views must be named here. ---
    $nameCams = @($hw | Get-VmsCamera)
    if ($cfg -and $cfg.HwName) {
        $ci = 0
        foreach ($cam in $nameCams) {
            $ci++
            $desiredName = if ($nameCams.Count -le 1) { $cfg.HwName } else { "{0} - Camera {1}" -f $cfg.HwName, $ci }
            if ($cam.Name -ne $desiredName) {
                try { $cam.Name = $desiredName; $cam.Save() }
                catch { Write-Warning ("  camera rename failed ({0}) - {1}" -f $cam.Name, $_.Exception.Message) }
            }
        }
    }

    # Re-fetch cameras FRESH after renaming. The rename Save() stales the camera objects, and
    # passing stale objects to Add-VmsDeviceGroupMember silently fails to persist the membership.
    $cams = @($hw | Get-VmsCamera)

    # --- Add all cameras to each device group. Add-VmsDeviceGroupMember is all-or-nothing and
    #     errors if ANY device is already a member (e.g. channel 0 is already in the import folder),
    #     so on that error fall back to adding one at a time - fresh group object each add to avoid
    #     the stale no-op - skipping cameras that are already members. ---
    foreach ($rg in $resolvedGroups) {
        try {
            Add-VmsDeviceGroupMember -Device $cams -Group $rg.Group -ErrorAction Stop
            Write-Host ("  Added {0} camera(s) to device group {1}" -f $cams.Count, $rg.Path) -ForegroundColor DarkGray
        } catch {
            $added = 0
            foreach ($cam in $cams) {
                try {
                    $fg = Get-VmsDeviceGroup -Path $rg.Path -Type Camera -ErrorAction Stop
                    Add-VmsDeviceGroupMember -Device $cam -Group $fg -ErrorAction Stop
                    $added++
                } catch {
                    if ($_.Exception.Message -notmatch 'already exists') {
                        Write-Warning ("  {0}: group add ({1}) failed - {2}" -f $cam.Name, $rg.Path, $_.Exception.Message)
                    }
                }
            }
            Write-Host ("  Added {0} new camera(s) to device group {1} (others were already members)" -f $added, $rg.Path) -ForegroundColor DarkGray
        }
    }

    # --- Per-lens settings ---
    foreach ($cam in $cams) {

        $streamsTouched = 0
        $settingsNotes  = New-Object System.Collections.Generic.List[string]

        # --- Stream settings: FPS (always), compression + Zipstream (if prompted) ---
        foreach ($stream in ($cam | Get-VmsCameraStream)) {
            $s = $stream.Settings
            if ($null -eq $s) { continue }
            $apply = @{}

            if ($cfg -and $s.ContainsKey('FPS')) { $apply['FPS'] = $cfg.FPS }

            if ($doComp) {
                if     ($s.ContainsKey('Compression')) { $apply['Compression'] = $compVal }
                elseif ($s.ContainsKey('Quality'))     { $apply['Quality']     = $compVal }
                else   { $settingsNotes.Add('no compression key on ' + $stream.DisplayName) }
            }
            if ($doZip) {
                if ($zStrength -and $s.ContainsKey('ZStrength')) { $apply['ZStrength'] = $zStrength }
                if ($zGop      -and $s.ContainsKey('ZGopMode'))  { $apply['ZGopMode']  = $zGop }
                if ($zFps      -and $s.ContainsKey('ZFpsMode'))  { $apply['ZFpsMode']  = $zFps }
                if ($zStrength -and -not $s.ContainsKey('ZStrength')) { $settingsNotes.Add('no Zipstream on ' + $stream.DisplayName) }
            }

            if ($apply.Count -gt 0) {
                try { $stream | Set-VmsCameraStream -Settings $apply -ErrorAction Stop; $streamsTouched++ }
                catch { $settingsNotes.Add('stream write failed: ' + $_.Exception.Message) }
            }
        }

        # --- Motion detection (enable + threshold) from the CSV, default on/200 ---
        if ($cfg -and $cfg.MotionOn) {
            try { $cam | Set-VmsCameraMotion -Enabled $true -Threshold $cfg.MotionThreshold -ErrorAction Stop | Out-Null }
            catch { $settingsNotes.Add('motion failed: ' + $_.Exception.Message) }
        }

        # --- Re-read actual post-change values for documentation ---
        $recStream = $cam | Get-VmsCameraStream -RecordingTrack Primary -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $recStream) { $recStream = $cam | Get-VmsCameraStream -LiveDefault -ErrorAction SilentlyContinue | Select-Object -First 1 }
        $rs = if ($recStream) { $recStream.Settings } else { $null }
        $motion = $cam | Get-VmsCameraMotion -ErrorAction SilentlyContinue

        $reportRows.Add([pscustomobject]@{
            HardwareHost     = Get-HwHost $hw
            Recorder         = $rec.Name
            HardwareName     = $hw.Name
            Model            = $hw.Model
            Address          = [string]$hw.Address
            CameraName       = $cam.Name
            Enabled          = $cam.Enabled
            MetadataEnabled  = $metaEnabled
            DeviceGroups     = ($groupPaths -join '; ')
            Is360OrMultiView = $is360
            ViewFlagReason   = $flagReason
            EnabledChannels  = $channelCount
            TotalChannels    = $totalChannels
            Codec            = Get-StreamValue $rs 'Codec'
            Resolution       = Get-StreamValue $rs @('Resolution','StreamResolution')
            FPS              = Get-StreamValue $rs @('FPS','Framerate','FrameRate')
            Compression      = Get-StreamValue $rs 'Compression'
            Quality          = Get-StreamValue $rs 'Quality'
            ZStrength        = Get-StreamValue $rs 'ZStrength'
            ZGopMode         = Get-StreamValue $rs 'ZGopMode'
            ZFpsMode         = Get-StreamValue $rs 'ZFpsMode'
            MotionEnabled    = Get-PropSafe $motion 'Enabled'
            MotionThreshold  = Get-PropSafe $motion 'Threshold'
            StreamsChanged   = $streamsTouched
            Notes            = ($settingsNotes -join '; ')
            Firmware         = $null
            MAC              = $null
        })
    }
}

# ============================================================================
#  Enrich the report with firmware / MAC from Get-VmsCameraReport
# ============================================================================
Write-Host "`nGathering firmware / MAC for documentation (Get-VmsCameraReport)..." -ForegroundColor Cyan
try {
    $camReport = @(Get-VmsCameraReport -RecordingServer $involved -EnableFilter All -ErrorAction Stop)
    $reportIndex = @{}
    foreach ($cr in $camReport) {
        $hn = Get-PropSafe $cr @('HardwareName','Hardware')
        $cn = Get-PropSafe $cr @('Name','CameraName')
        if ($hn -and $cn) { $reportIndex[("{0}|{1}" -f $hn, $cn)] = $cr }
    }
    foreach ($rr in $reportRows) {
        $key = "{0}|{1}" -f $rr.HardwareName, $rr.CameraName
        if ($reportIndex.ContainsKey($key)) {
            $cr = $reportIndex[$key]
            $rr.Firmware = Get-PropSafe $cr @('Firmware','FirmwareVersion')
            $rr.MAC      = Get-PropSafe $cr @('MAC','MacAddress','Mac')
        }
    }
} catch {
    Write-Warning "Get-VmsCameraReport failed - firmware/MAC will be blank. ($($_.Exception.Message))"
}

# ============================================================================
#  Summary + output
# ============================================================================
$added   = @($rowStatus | Where-Object Status -eq 'Added')
$failed  = @($rowStatus | Where-Object Status -eq 'Failed')
$existed = @($rowStatus | Where-Object Status -eq 'AlreadyExisted')
$flags   = @($reportRows | Where-Object Is360OrMultiView -eq $true | Select-Object -ExpandProperty HardwareName -Unique)

Write-Host ""
Write-Host ("Added:   {0} row(s), {1} lens(es)." -f $added.Count, $reportRows.Count) -ForegroundColor Green
if ($existed.Count -gt 0) { Write-Host ("Skipped: {0} row(s) already existed." -f $existed.Count) -ForegroundColor Yellow }
if ($failed.Count -gt 0) {
    Write-Host ("Failed:  {0} row(s) (offline, wrong creds, or non-Axis with a blank driver):" -f $failed.Count) -ForegroundColor Red
    $failed | Select-Object IP, Name, Recorder, Driver | Format-Table -AutoSize
}
if ($flags.Count -gt 0) {
    Write-Host ("360 / multi-view cameras to review (disable extra views / turn off recording): {0}" -f ($flags -join ', ')) -ForegroundColor Magenta
}

$sorted = $reportRows | Sort-Object Recorder, HardwareName, CameraName
$sorted | Out-GridView -Title ("Added cameras - documentation report ({0} lens(es))" -f $reportRows.Count)

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
    $ReportPath = Join-Path $env:USERPROFILE ("Downloads\AddedCameras_{0}.csv" -f $stamp)
}
try { $sorted | Export-Csv -Path $ReportPath -NoTypeInformation; Write-Host ("Report exported to: {0}" -f $ReportPath) -ForegroundColor Green }
catch { Write-Warning "Report export failed: $($_.Exception.Message)" }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " MANUAL FOLLOW-UP STILL REQUIRED - this is not run-and-forget" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " This script handled the bulk of the work, but on EACH camera you still need to:" -ForegroundColor Yellow
Write-Host "   1. Review motion detection EXCLUSION REGIONS (none are set by this script)." -ForegroundColor Yellow
Write-Host "   2. Verify the CORRECT STREAMS are recording (and at the intended resolution)." -ForegroundColor Yellow
Write-Host "   3. Check the 360 / multi-view cameras flagged above and disable extra views / recording as needed." -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow

Write-Host "Done." -ForegroundColor Green
