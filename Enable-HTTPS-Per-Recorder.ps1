Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# Ask what to do
$action = [System.Windows.Forms.MessageBox]::Show(
    "Click YES to ENABLE HTTPS settings`nClick NO to DISABLE HTTPS settings",
    "HTTPS Configuration",
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
)

if ($action -eq [System.Windows.Forms.DialogResult]::Cancel) {
    Write-Warning "Cancelled."
    return
}

$enable = $action -eq [System.Windows.Forms.DialogResult]::Yes

# Ask for port
$port = Read-Host "Enter HTTPS port (press Enter for default 443)"
if ([string]::IsNullOrWhiteSpace($port)) { $port = "443" }

# Confirm
$modeText = if ($enable) { "ENABLE" } else { "DISABLE" }
Write-Host "`nMode: $modeText | Port: $port" -ForegroundColor Cyan

$recorders = Get-VmsRecordingServer | Out-GridView -Title "Select Recording Server(s)" -OutputMode Multiple
if ($null -eq $recorders) {
    Write-Warning "No recording server selected."
    return
}

Add-Type -AssemblyName System.Windows.Forms

foreach ($rec in $recorders) {
    Write-Host "Processing $($rec.Name)" -ForegroundColor Cyan
    $deviceList = $rec | Get-VmsHardware
    Write-Host "Found $($deviceList.Count) devices." -ForegroundColor Yellow

    foreach ($device in $deviceList) {
        Write-Host "  Configuring: $($device.Name)" -ForegroundColor Gray
        try {
            $freshDevice = $rec | Get-VmsHardware | Where-Object { $_.Id -eq $device.Id }
            $s = $freshDevice | Get-HardwareSetting

            if ($enable) {
                if ($s.HTTPSEnabled -ne "yes")             { $freshDevice | Set-HardwareSetting -Name HTTPSEnabled -Value yes -ErrorAction Stop }
                if ($s.HTTPSPort -ne $port)                { $freshDevice | Set-HardwareSetting -Name HTTPSPort -Value $port -ErrorAction Stop }
                if ($s.HTTPSValidateCertificate -ne "Yes") { $freshDevice | Set-HardwareSetting -Name HTTPSValidateCertificate -Value Yes -ErrorAction Stop }
                if ($s.HTTPSValidateHostname -ne "Yes")    { $freshDevice | Set-HardwareSetting -Name HTTPSValidateHostname -Value Yes -ErrorAction Stop }
            } else {
                if ($s.HTTPSValidateCertificate -ne "No")  { $freshDevice | Set-HardwareSetting -Name HTTPSValidateCertificate -Value No -ErrorAction Stop }
                if ($s.HTTPSValidateHostname -ne "No")     { $freshDevice | Set-HardwareSetting -Name HTTPSValidateHostname -Value No -ErrorAction Stop }
                if ($s.HTTPSEnabled -ne "no")              { $freshDevice | Set-HardwareSetting -Name HTTPSEnabled -Value no -ErrorAction Stop }
            }

            Write-Host "  Done: $($device.Name)" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed: $($device.Name) - $_"
        }
    }
    Write-Host "Completed $($rec.Name)" -ForegroundColor Cyan
}