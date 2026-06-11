Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula

$default = "$env:USERPROFILE\Downloads\Hardware_List.csv"
$OutputPath = Read-Host "Save to (press Enter for $default)"
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $default }

Get-VmsHardware -Verbose | Export-Csv $OutputPath -NoTypeInformation
Write-Host "Exported to: $OutputPath" -ForegroundColor Green
