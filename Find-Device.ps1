# Find-Device.ps1
# Locate hardware/cameras across one or more recording servers by Name, IP/Address, MAC,
# or Serial number. Shows the parent hardware, recording server, address, MAC, serial,
# model, and camera channels for each match. GridView results + optional CSV export.
#
# Name / Address searches are fast (config fields). MAC / Serial require reading each
# device's hardware settings from the recorder, so those searches scan and take longer.

# Import module
Import-Module MilestonePSTools -ErrorAction Stop

# Connect via dialog (lets user pick server)
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# --- Helpers ---
function Get-HwInfo {
    param($Hardware)
    # Returns MAC/Serial/Firmware from hardware settings; blank on failure (e.g. offline).
    try {
        $s = $Hardware | Get-HardwareSetting -ErrorAction Stop
        [pscustomobject]@{ Mac = $s.MACAddress; Serial = $s.SerialNumber; Firmware = $s.FirmwareVersion }
    } catch {
        [pscustomobject]@{ Mac = ''; Serial = ''; Firmware = '' }
    }
}
function Format-Mac { param($m); if (-not $m) { return '' }; return (($m -replace '[^0-9A-Fa-f]', '')).ToLower() }

# --- Pick recording servers to search ---
$recorders = Get-VmsRecordingServer |
    Sort-Object Name |
    Out-GridView -Title "Select recording server(s) to search (select all for everything)" -OutputMode Multiple
if (-not $recorders) { Write-Warning "No recording server selected. Nothing to do."; return }

# --- Choose what to search by ---
$field = @('Name', 'Address (IP)', 'MAC', 'Serial') |
    ForEach-Object { [pscustomobject]@{ 'Search by' = $_ } } |
    Out-GridView -Title "Search by..." -OutputMode Single
if (-not $field) { Write-Host "No search type chosen." -ForegroundColor Red; return }
$searchBy = $field.'Search by'

$term = Read-Host "Enter the $searchBy to search for (partial matches OK)"
if ([string]::IsNullOrWhiteSpace($term)) { Write-Host "No search term entered." -ForegroundColor Red; return }

$needsScan = $searchBy -in @('MAC', 'Serial')
if ($needsScan) {
    Write-Host "Searching by $searchBy reads settings from every device - this can take a while..." -ForegroundColor Yellow
} else {
    Write-Host "Searching by $searchBy on $(($recorders | Measure-Object).Count) server(s)..." -ForegroundColor Cyan
}

$termMac = Format-Mac $term

# --- Search ---
$results = foreach ($rec in $recorders) {
    foreach ($hw in ($rec | Get-VmsHardware)) {
        $cams     = @($hw | Get-VmsCamera -EnableFilter All)
        $camNames = @($cams | ForEach-Object { $_.Name })

        $match = $false
        $info  = $null   # lazily fetched hardware settings (MAC/serial)

        switch ($searchBy) {
            'Name' {
                $match = ($hw.Name -like "*$term*") -or ([bool](@($camNames) -like "*$term*"))
            }
            'Address (IP)' {
                $match = ($hw.Address -like "*$term*")
            }
            'MAC' {
                $info  = Get-HwInfo $hw
                $match = (Format-Mac $info.Mac) -like "*$termMac*" -and $termMac -ne ''
            }
            'Serial' {
                $info  = Get-HwInfo $hw
                $match = ($info.Serial -like "*$term*")
            }
        }

        if ($match) {
            if ($null -eq $info) { $info = Get-HwInfo $hw }   # enrich matches for display
            [pscustomobject]@{
                RecordingServer = $rec.Name
                HardwareName    = $hw.Name
                Cameras         = ($camNames -join '; ')
                Address         = $hw.Address
                MAC             = $info.Mac
                Serial          = $info.Serial
                Model           = $hw.Model
                Firmware        = $info.Firmware
                Enabled         = $hw.Enabled
            }
        }
    }
}

$results = @($results)
if (-not $results) { Write-Warning "No devices matched '$term' by $searchBy."; return }

Write-Host "Found $($results.Count) match(es)." -ForegroundColor Green
$sorted = $results | Sort-Object RecordingServer, HardwareName
$sorted | Out-GridView -Title "Matches for '$term' ($searchBy)"

# --- Optional CSV export ---
$answer = Read-Host "Export results to CSV? (y/N)"
if ($answer -match '^(y|yes)$') {
    $default = Join-Path $env:USERPROFILE "Downloads\DeviceSearch_$($searchBy -replace '[^\w\-]', '')_$($term -replace '[^\w\-]', '').csv"
    $path = Read-Host "Save to (press Enter for $default)"
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $default }
    $sorted | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Exported to: $path" -ForegroundColor Green
}
