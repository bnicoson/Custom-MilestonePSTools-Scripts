<#
    Test-AddCamerasEnvironment.ps1
    ----------------------------------------------------------------------------
    READ-ONLY probe for Add-CamerasFromCsv.ps1. Adds/changes NOTHING.
    Confirms the assumptions the main script makes but can't verify without a live VMS:
      1. The cmdlets it relies on exist.
      2. The real stream Settings KEY NAMES on an Axis camera (Zipstream / compression).
      3. The metadata device shape (Get-VmsMetadata).
      4. The real Get-VmsCameraReport COLUMN NAMES for firmware / MAC.
#>

param(
    [string]$Server,                       # e.g. MGMT-SERVER.example.local; omit to use the login dialog
    [string]$TargetIp = '192.168.1.100'    # an existing camera IP to probe (already added to the VMS)
)

if ($PSVersionTable.PSEdition -eq 'Core') {
    throw "Run this in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh). MilestonePSTools requires .NET Framework."
}

Import-Module MilestonePSTools -ErrorAction Stop
if ($Server) { Connect-ManagementServer -Server $Server -AcceptEula -Force }
else         { Connect-ManagementServer -ShowDialog -AcceptEula -Force }
Write-Host "Connected." -ForegroundColor Green

Write-Host "`n=== 1. Required cmdlets ===" -ForegroundColor Cyan
'Import-VmsHardware','Get-VmsMetadata','Set-VmsMetadata','Set-VmsCameraStream',
'Set-VmsCameraMotion','Get-VmsCameraReport','Get-VmsHardwareDriver','Get-VmsCameraStream' | ForEach-Object {
    $c = Get-Command $_ -ErrorAction SilentlyContinue
    "{0,-24} {1}" -f $_, $(if ($c) { "OK" } else { "*** MISSING ***" })
}

Write-Host "`n=== 2. Target hardware $TargetIp ===" -ForegroundColor Cyan
$hw = Get-VmsHardware | Where-Object { try { ([uri]([string]$_.Address)).Host -eq $TargetIp } catch { $false } } | Select-Object -First 1
if (-not $hw) { Write-Warning "Hardware $TargetIp not found."; return }
"{0}  [{1}]" -f $hw.Name, $hw.Model

Write-Host "`n=== 3. Metadata device(s) (Get-VmsMetadata -EnableFilter All) ===" -ForegroundColor Cyan
foreach ($md in (Get-VmsMetadata -Hardware $hw -EnableFilter All)) { "  {0}  Enabled={1}" -f $md.Name, $md.Enabled }

Write-Host "`n=== 4. Stream Settings keys on the recorded stream ===" -ForegroundColor Cyan
$cam = $hw | Get-VmsCamera | Select-Object -First 1
$stream = $cam | Get-VmsCameraStream -RecordingTrack Primary -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $stream) { $stream = $cam | Get-VmsCameraStream -LiveDefault -ErrorAction SilentlyContinue | Select-Object -First 1 }
if ($stream -and $stream.Settings) {
    Write-Host "All keys:" -ForegroundColor Yellow
    $stream.Settings.Keys | Sort-Object | ForEach-Object { "  {0} = {1}" -f $_, $stream.Settings[$_] }
    Write-Host "Assumed keys present?" -ForegroundColor Yellow
    'Compression','Quality','ZStrength','ZGopMode','ZFpsMode','Codec' | ForEach-Object {
        "  {0,-14} {1}" -f $_, $(if ($stream.Settings.ContainsKey($_)) { "YES ($($stream.Settings[$_]))" } else { "no" })
    }
} else { Write-Warning "Could not read stream settings." }

Write-Host "`n=== 5. Get-VmsCameraReport columns (firmware / MAC) ===" -ForegroundColor Cyan
$rec = Get-VmsRecordingServer | Select-Object -First 1
$rep = @(Get-VmsCameraReport -RecordingServer $rec -EnableFilter All -ErrorAction SilentlyContinue) |
    Where-Object { $_.PSObject.Properties['HardwareName'] -and $_.HardwareName -eq $hw.Name } | Select-Object -First 1
if (-not $rep) { $rep = @(Get-VmsCameraReport -RecordingServer $rec -EnableFilter All -ErrorAction SilentlyContinue) | Select-Object -First 1 }
if ($rep) {
    Write-Host "All columns:" -ForegroundColor Yellow
    $rep.PSObject.Properties.Name | Sort-Object | ForEach-Object { "  $_" }
    Write-Host "Firmware/MAC-looking columns:" -ForegroundColor Yellow
    $rep.PSObject.Properties | Where-Object { $_.Name -match 'firm|mac' } | ForEach-Object { "  {0} = {1}" -f $_.Name, $_.Value }
} else { Write-Warning "Get-VmsCameraReport returned nothing." }

Write-Host "`n=== 6. Import/Export CSV schema (confirm the DeviceGroups column) ===" -ForegroundColor Cyan
$exportCsv = Join-Path $env:TEMP 'vms_export_schema_sample.csv'
try {
    $hw | Export-VmsHardware -Path $exportCsv -DeviceType Camera -EnableFilter All -ErrorAction Stop
    Write-Host "Column headers:" -ForegroundColor Yellow
    (Get-Content $exportCsv -TotalCount 1)
    $first = Import-Csv $exportCsv | Select-Object -First 1
    Write-Host ("DeviceGroups value on sample: {0}" -f $first.DeviceGroups) -ForegroundColor Yellow
    Write-Host "(sample written to $exportCsv - delete when done)"
} catch { Write-Warning "Export-VmsHardware failed: $($_.Exception.Message)" }

Write-Host "`n=== 7. Device group cmdlets available ===" -ForegroundColor Cyan
Get-Command -Module MilestonePSTools -Name '*DeviceGroup*' | Select-Object -ExpandProperty Name | Sort-Object

Write-Host "`nDone (read-only)." -ForegroundColor Green
