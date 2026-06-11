Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force

Write-Host "Retrieving all hardware..." -ForegroundColor Cyan
$AllHardware = @(Get-VmsHardware)
Write-Host "Found $($AllHardware.Count) device(s)." -ForegroundColor Yellow

$port = Read-Host "`nEnter HTTPS port (press Enter for default 443)"
if ([string]::IsNullOrWhiteSpace($port)) { $port = "443" }

$confirm = Read-Host "This will ENABLE HTTPS on ALL $($AllHardware.Count) device(s) on port $port. Continue? (yes/no)"
if ($confirm -ne 'yes') {
    Write-Host "Cancelled." -ForegroundColor Red
    exit
}

foreach ($device in $AllHardware) {
    Write-Host "  Configuring: $($device.Name)" -ForegroundColor Gray
    try {
        $device | Set-HardwareSetting -Name HTTPSEnabled           -Value yes  -ErrorAction Stop
        $device | Set-HardwareSetting -Name HTTPSPort              -Value $port -ErrorAction Stop
        $device | Set-HardwareSetting -Name HTTPSValidateCertificate -Value Yes -ErrorAction Stop
        $device | Set-HardwareSetting -Name HTTPSValidateHostname  -Value Yes  -ErrorAction Stop
        Write-Host "  Done: $($device.Name)" -ForegroundColor Green
    }
    catch {
        Write-Warning "  Failed: $($device.Name) - $_"
    }
}

Write-Host "`nHTTPS configuration complete." -ForegroundColor Green
