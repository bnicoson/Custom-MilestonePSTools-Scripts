# Balance-RecorderLoad.ps1
# Analyze recording load across selected recording servers and propose (then optionally
# execute) hardware moves to balance them.
#
# LOAD is a COMPOSITE of three metrics, each normalized to its share of the total across all
# hardware, then weighted and summed into one unitless Load score:
#   resolution (0.4) + camera/channel count (0.4) + storage used (0.2)
# Resolution (total megapixels of the recorded streams) is used instead of bitrate: in this
# environment bitrate is configured uniformly, so it doesn't differentiate load - resolution
# does. Storage is a modest signal for the footprint a camera will consume over time.
# Only RECORDING-ENABLED channels are counted - live-only views (e.g. the de-warped sub-views
# of a fisheye where only the main 360 records) are excluded so they don't inflate load.
# Weights tunable below.
#
# CAPACITY-WEIGHTED: servers are balanced proportional to their ARCHIVE storage capacity (the
# archive MaxSize - the real long-term retention drive), not a flat split, so a bigger server
# gets a bigger target. Live storage is only a short buffer and is ignored unless a recorder
# has no archive (then its live size is used). Falls back to equal capacity if sizes can't be read.
#
# Moves are performed at the HARDWARE level (a device + all its channels) via Move-VmsHardware.
#
# ============================ READ BEFORE EXECUTING ============================
#  * MOVE-HISTORY PROTECTION: Milestone only carries recordings across ONE server move.
#    Moving a camera that was recently moved would orphan its earlier history. There is no
#    true "last moved" field, so this uses the age of the oldest recording on the current
#    server (MediaDatabaseBegin) as a proxy: any hardware whose oldest recording is newer than
#    $RecentMoveWindowDays is HELD BACK (not moved) and listed with a reason. Conservative on
#    purpose - it will not move anything that looks recently established.
#  * Existing recordings DO NOT move - footage stays on the source recorder and ages out; only
#    new recordings go to the destination.
#  * NETWORK REACHABILITY: the destination recorder must reach each camera's IP / VLAN. This
#    script CANNOT verify that - you must confirm it before executing or the moves will fail.
#  * Device pack versions should match between recorders, or use the Skip driver check option.
# ===============================================================================

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# --- Tunables ---
# Composite load weights (should sum to 1.0).
#   Resolution - total megapixels of the recorded streams. Primary load differentiator here,
#                since bitrate is set uniformly across cameras; higher-res and multi-channel
#                devices score higher. (Bitrate is intentionally not used for this reason.)
#   Count      - always reliable; spreads cameras evenly and stabilizes the plan.
#   Storage    - used disk. Existing footage does NOT move, but proxies the footprint a camera
#                will consume on the new server over time. Modest weight so a few huge-storage
#                cameras don't dominate and under-move the plan (which happened at 1/3 weight).
$W_Resolution = 0.4   # composite weight: recorded resolution (megapixels)
$W_Count      = 0.4   # composite weight: camera/channel count
$W_Storage    = 0.2   # composite weight: storage used (future-footprint proxy)
$Tolerance = 0.01    # balance band: stop when (over-target) spread <= 2x this (tighter = fuller fill)
$RecentMoveWindowDays = 30   # hold back hardware whose oldest recording is newer than this

# Optional MANUAL capacity override. By default capacity = configured archive MaxSize, which
# reflects how much Milestone is allowed to write - that may NOT match physical drive size
# (e.g. a newer recorder whose archive MaxSize isn't set to its full disk yet). To balance by
# physical/known capacity instead, list "<exact server name>" = <size> (any consistent unit;
# TB is fine). Servers not listed fall back to their archive MaxSize. Use the EXACT recorder
# display names shown in the recorder picker / the BEFORE table.
$CapacityOverride = @{
    # 'Recording Server 1' = 112
    # 'Recording Server 2' = 86.9
}

# --- Helpers ---
function Format-Guid { param($g); if (-not $g) { return '' }; return (("$g").Trim('{', '}')).ToLower() }
function Sum-Prop { param($Items, [string]$Prop); $s = ($Items | Measure-Object -Property $Prop -Sum).Sum; if ($null -eq $s) { 0 } else { $s } }
function Get-Megapixels {
    param($Row)
    $res = "$($Row.CurrentRecordedResolution)"; if ([string]::IsNullOrWhiteSpace($res)) { $res = "$($Row.ConfiguredRecordedResolution)" }
    if ($res -match '(\d+)\s*[xX]\s*(\d+)') { return ([double]$Matches[1] * [double]$Matches[2]) / 1e6 }
    return 2.07   # ~1080p fallback when resolution isn't reported
}
# Storage size property. Live/archive storage expose MaxSize (configured max recording size,
# in MB); other names kept as fallbacks for version differences. Units cancel since the same
# property is summed across all servers for a relative capacity share.
$SizeProps = @('MaxSize', 'MaximumSizeMB', 'MaxSizeMB', 'MaximumSize', 'MaxSizeInBytes', 'Size')
function Get-StorageSize {
    param($Storage)
    foreach ($p in $SizeProps) {
        if ($Storage.PSObject.Properties.Match($p).Count -gt 0) {
            $v = $Storage.$p -as [double]
            if ($v -and $v -gt 0) { return $v }
        }
    }
    return 0
}
function Get-ServerStats {
    param($AssignMap, $HwList, $Servers, $CapShare)
    foreach ($s in $Servers) {
        $items = @($HwList | Where-Object { $AssignMap[$_.HwId] -eq $s })
        [pscustomobject]@{
            Server      = $s
            Cams         = [int](Sum-Prop $items 'Cams')
            ResolutionMP = [math]::Round((Sum-Prop $items 'ResMP'), 1)
            StorageGB    = [math]::Round((Sum-Prop $items 'StorageGB'), 1)
            LoadPct     = [math]::Round((Sum-Prop $items 'Load') * 100, 1)
            TargetPct   = [math]::Round($CapShare[$s] * 100, 1)
        }
    }
}

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Pick recording servers to balance (need at least 2) ---
$recorders = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select recording servers to balance (2 or more)" -OutputMode Multiple
if (-not $recorders -or ($recorders | Measure-Object).Count -lt 2) {
    Write-Warning "Select at least two recording servers to balance."; return
}
$recByName = @{}; foreach ($rec in $recorders) { $recByName[$rec.Name] = $rec }
$servers   = @($recorders | ForEach-Object { $_.Name })

# --- Capacity per recorder (sum of storage max sizes; equal fallback) ---
Write-Host "Reading recorder storage capacity..." -ForegroundColor Cyan
$capByServer = @{}; $capFound = $false
foreach ($rec in $recorders) {
    # Manual override wins if provided for this server.
    if ($CapacityOverride.ContainsKey($rec.Name)) {
        $capByServer[$rec.Name] = [double]$CapacityOverride[$rec.Name]
        if ($capByServer[$rec.Name] -gt 0) { $capFound = $true }
        continue
    }
    $liveCap = 0.0; $archiveCap = 0.0
    foreach ($st in ($rec | Get-VmsStorage)) {
        $liveCap += (Get-StorageSize $st)
        foreach ($ar in ($st | Get-VmsArchiveStorage)) { $archiveCap += (Get-StorageSize $ar) }
    }
    # Capacity = ARCHIVE size (the real long-term retention). Live is only a short buffer
    # (12-24h). Fall back to live only if a recorder has no archive configured.
    $c = if ($archiveCap -gt 0) { $archiveCap } else { $liveCap }
    $capByServer[$rec.Name] = $c
    if ($c -gt 0) { $capFound = $true }
}
$sumCap = ($capByServer.Values | Measure-Object -Sum).Sum
if (-not $capFound -or $sumCap -le 0) {
    Write-Warning "Could not read recorder storage sizes - balancing with EQUAL capacity for all servers."
    foreach ($s in $servers) { $capByServer[$s] = 1 }
    $sumCap = $servers.Count
}
$capShare = @{}; foreach ($s in $servers) { $capShare[$s] = $capByServer[$s] / $sumCap }

Write-Host "Composite weights -> resolution $([math]::Round($W_Resolution,2)) / count $([math]::Round($W_Count,2)) / storage $([math]::Round($W_Storage,2))" -ForegroundColor Cyan
Write-Host "Gathering load data (this can take a while)..." -ForegroundColor Cyan

# --- Hardware objects by Id ---
$hwById = @{}
foreach ($rec in $recorders) { foreach ($hw in ($rec | Get-VmsHardware)) { $hwById[(Format-Guid $hw.Id)] = $hw } }

# --- Camera report -> aggregate per hardware ---
$report = Get-VmsCameraReport -RecordingServer $recorders -IncludeRetentionInfo -Verbose
$agg = @{}
foreach ($r in $report) {
    $hid = Format-Guid $r.HardwareId
    if (-not $hwById.ContainsKey($hid)) { continue }
    # Only recording-enabled channels drive recording load. Skip live-only views (e.g. the
    # de-warped sub-views of a fisheye where only the main 360 records) so they don't inflate
    # a device's load. RecordingEnabled must be explicitly False to skip (nulls are kept).
    if ($r.RecordingEnabled -eq $false) { continue }
    if (-not $agg.ContainsKey($hid)) {
        $agg[$hid] = [pscustomobject]@{
            HwId = $hid; Hardware = $hwById[$hid]; HardwareName = $r.HardwareName
            Recorder = $r.RecorderName; ResMP = 0.0; Cams = 0; StorageGB = 0.0; FirstRec = $null
        }
    }
    $a = $agg[$hid]
    $a.Cams++
    $a.ResMP += (Get-Megapixels $r)
    $sg = $r.UsedSpaceInGB -as [double]; if ($sg) { $a.StorageGB += $sg }
    $mb = $r.MediaDatabaseBegin -as [datetime]
    if ($mb -and (-not $a.FirstRec -or $mb -lt $a.FirstRec)) { $a.FirstRec = $mb }
}
$hwList = @($agg.Values | Where-Object { $_.Hardware -and $servers -contains $_.Recorder })
if (-not $hwList) { Write-Warning "No movable hardware found on the selected servers."; return }

# --- Composite Load + move-history hold-back ---
$sumR = Sum-Prop $hwList 'ResMP';     if ($sumR -le 0) { $sumR = 1 }
$sumC = Sum-Prop $hwList 'Cams';      if ($sumC -le 0) { $sumC = 1 }
$sumS = Sum-Prop $hwList 'StorageGB'; if ($sumS -le 0) { $sumS = 1 }
$nowUtc = (Get-Date).ToUniversalTime()
foreach ($h in $hwList) {
    $load = ($W_Resolution * ($h.ResMP / $sumR)) + ($W_Count * ($h.Cams / $sumC)) + ($W_Storage * ($h.StorageGB / $sumS))
    $h | Add-Member -NotePropertyName Load -NotePropertyValue ([double]$load) -Force

    if ($h.FirstRec) {
        $daysOn = [math]::Round(($nowUtc - $h.FirstRec.ToUniversalTime()).TotalDays, 1)
    } else {
        $daysOn = $null
    }
    $h | Add-Member -NotePropertyName DaysOnServer -NotePropertyValue $daysOn -Force
    # Hold back if the oldest recording on this server is newer than the window (recently moved/added).
    $hold = ($null -ne $daysOn) -and ($daysOn -lt $RecentMoveWindowDays)
    $h | Add-Member -NotePropertyName Movable -NotePropertyValue (-not $hold) -Force
    $h | Add-Member -NotePropertyName HoldReason -NotePropertyValue ($(if ($hold) { "oldest recording only ${daysOn}d old - may have been moved recently" } else { '' })) -Force
}

$held = @($hwList | Where-Object { -not $_.Movable })
if ($held.Count) {
    Write-Host "`n$($held.Count) hardware HELD BACK (recently established on their server; moving risks orphaning history):" -ForegroundColor DarkYellow
    $held | Select-Object HardwareName, Recorder, DaysOnServer, HoldReason | Sort-Object DaysOnServer |
        Format-Table -AutoSize | Out-String | Write-Host
}

# --- Capacity-aware greedy balancing (move-minimizing) ---
$currentAssign = @{}; foreach ($h in $hwList) { $currentAssign[$h.HwId] = $h.Recorder }
$assign = @{}; foreach ($k in $currentAssign.Keys) { $assign[$k] = $currentAssign[$k] }

$totalLoad = Sum-Prop $hwList 'Load'
$target = @{}; foreach ($s in $servers) { $target[$s] = $totalLoad * $capShare[$s] }
$srvLoad = @{}; foreach ($s in $servers) { $srvLoad[$s] = Sum-Prop @($hwList | Where-Object { $assign[$_.HwId] -eq $s }) 'Load' }

$moves = New-Object System.Collections.Generic.List[object]
$guard = 0
while ($true) {
    $guard++; if ($guard -gt 100000) { break }
    $hot  = ($servers | Sort-Object { $srvLoad[$_] - $target[$_] } -Descending)[0]
    $cold = ($servers | Sort-Object { $srvLoad[$_] - $target[$_] })[0]
    $gap  = ($srvLoad[$hot] - $target[$hot]) - ($srvLoad[$cold] - $target[$cold])
    if ($gap -le (2 * $Tolerance)) { break }

    $cands = @($hwList | Where-Object { $assign[$_.HwId] -eq $hot -and $_.Movable })
    if (-not $cands) { break }
    $fit = @($cands | Where-Object { $_.Load -le $gap } | Sort-Object Load -Descending)[0]
    if (-not $fit) { $fit = @($cands | Sort-Object Load)[0] }

    $newHotOver  = ($srvLoad[$hot] - $fit.Load) - $target[$hot]
    $newColdOver = ($srvLoad[$cold] + $fit.Load) - $target[$cold]
    if (([math]::Abs($newHotOver - $newColdOver)) -ge $gap) { break }   # no improvement -> stop

    $assign[$fit.HwId] = $cold
    $srvLoad[$hot] -= $fit.Load; $srvLoad[$cold] += $fit.Load
    $moves.Add([pscustomobject]@{
        Hardware = $fit.Hardware; HardwareName = $fit.HardwareName; Cams = $fit.Cams
        ResolutionMP = [math]::Round($fit.ResMP, 1); StorageGB = [math]::Round($fit.StorageGB, 1)
        LoadPct = [math]::Round($fit.Load * 100, 2); DaysOnServer = $fit.DaysOnServer
        From = $currentAssign[$fit.HwId]; To = $cold
    })
}

# --- Report the plan (LoadPct vs TargetPct = capacity share) ---
$before = Get-ServerStats $currentAssign $hwList $servers $capShare
$after  = Get-ServerStats $assign        $hwList $servers $capShare
Write-Host "`n=== BEFORE (LoadPct vs TargetPct = capacity share) ===" -ForegroundColor Yellow
$before | Sort-Object LoadPct -Descending | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "=== AFTER (proposed) ===" -ForegroundColor Yellow
$after  | Sort-Object LoadPct -Descending | Format-Table -AutoSize | Out-String | Write-Host

if ($moves.Count -eq 0) {
    Write-Host "Already balanced within tolerance (or nothing movable) - no moves proposed." -ForegroundColor Green
    $before | Out-GridView -Title "Recorder load (no moves)"
    return
}

Write-Host "$($moves.Count) hardware move(s) proposed.`n" -ForegroundColor Cyan

# Tag each proposed move with an index so grid selections map back to the real hardware object.
$i = 0; foreach ($m in $moves) { $m | Add-Member -NotePropertyName Idx -NotePropertyValue (++$i) -Force }

# Save the FULL proposed plan for the record (regardless of what you choose to execute).
$stamp    = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss')
$planPath = Join-Path $env:USERPROFILE "Downloads\RecorderBalancePlan_$stamp.csv"
$moves | Select-Object Idx, HardwareName, Cams, ResolutionMP, StorageGB, LoadPct, DaysOnServer, From, To | Export-Csv -Path $planPath -NoTypeInformation
Write-Host "Full plan saved to: $planPath" -ForegroundColor Green

# --- Select which moves to execute (THIS grid is the approval gate) ---
# Select all = execute the whole plan. Select a subset = only those move. Cancel/none = abort.
$selected = $moves |
    Select-Object Idx, HardwareName, Cams, ResolutionMP, StorageGB, LoadPct, DaysOnServer, From, To |
    Out-GridView -Title "SELECT the moves to EXECUTE (Ctrl/Shift; select all = full plan). Only selected rows move; Cancel = no changes." -OutputMode Multiple
if (-not $selected) { Write-Host "No moves selected - plan only, no changes made." -ForegroundColor Red; return }

$selIdx = @($selected | ForEach-Object { $_.Idx })
$toMove = @($moves | Where-Object { $selIdx -contains $_.Idx })

# --- Execute ---
Write-Host "`nReachability check: each destination recorder MUST reach the camera networks it will receive." -ForegroundColor Yellow
$confirm = Read-Host "Execute the $($toMove.Count) SELECTED move(s)? Only 'yes' proceeds"
if ($confirm -ne 'yes') { Write-Host "Cancelled - no changes made." -ForegroundColor Red; return }

$sd   = Read-Host "Skip device-pack driver version check? (needed if recorders run different device packs) (y/N)"
$skip = $sd -match '^(y|yes)$'

$destinations  = @($toMove | Select-Object -ExpandProperty To -Unique)
$storageByDest = @{}
foreach ($d in $destinations) {
    $st = $recByName[$d] | Get-VmsStorage | Out-GridView -Title "Select destination STORAGE on '$d'" -OutputMode Single
    if (-not $st) { Write-Warning "No storage chosen for '$d' - moves to it will be skipped." }
    $storageByDest[$d] = $st
}

$log = New-Object System.Collections.Generic.List[object]
foreach ($d in $destinations) {
    $storage = $storageByDest[$d]
    $group   = @($toMove | Where-Object To -eq $d)
    if (-not $storage) {
        foreach ($m in $group) { $log.Add([pscustomobject]@{ Hardware = $m.HardwareName; From = $m.From; To = $d; Result = 'Skipped - no storage' }) }
        continue
    }
    $hwObjs = @($group | ForEach-Object { $_.Hardware })
    try {
        $params = @{ Hardware = $hwObjs; DestinationRecorder = $recByName[$d]; DestinationStorage = $storage; Confirm = $false; ErrorAction = 'Stop' }
        if ($skip) { $params['SkipDriverCheck'] = $true }
        Move-VmsHardware @params | Out-Null
        foreach ($m in $group) { $log.Add([pscustomobject]@{ Hardware = $m.HardwareName; From = $m.From; To = $d; Result = 'Moved' }) }
        Write-Host "Moved $($group.Count) hardware -> $d" -ForegroundColor Green
    } catch {
        foreach ($m in $group) { $log.Add([pscustomobject]@{ Hardware = $m.HardwareName; From = $m.From; To = $d; Result = "Failed: $($_.Exception.Message)" }) }
        Write-Warning "Move to '$d' FAILED: $($_.Exception.Message)"
    }
}

$moved = @($log | Where-Object Result -eq 'Moved').Count
Write-Host "`nDone. $moved hardware moved." -ForegroundColor Green
$log | Out-GridView -Title "Move results"
$logPath = Join-Path $env:USERPROFILE "Downloads\RecorderBalanceLog_$stamp.csv"
$log | Export-Csv -Path $logPath -NoTypeInformation
Write-Host "Move log saved to: $logPath" -ForegroundColor Green
