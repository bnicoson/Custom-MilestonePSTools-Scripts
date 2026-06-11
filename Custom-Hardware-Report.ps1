# WARNING: The output CSV will contain camera passwords in plaintext. Handle and store the file accordingly.

Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force
$macProperty = @{
    Name       = 'MACAddress'
    Expression = { ($_ | Get-HardwareSetting).MACAddress }
}
$Firmware = @{
    Name       = 'FirmwareVersion'
    Expression = { ($_ | Get-HardwareSetting).FirmwareVersion }
}
$SerialNumber = @{
    Name       = 'SerialNumber'
    Expression = { ($_ | Get-HardwareSetting).SerialNumber }
}
$Password = @{
    Name       = 'Password'
    Expression = { ($_ | Get-VmsHardwarePassword) }
}
$default = "$env:USERPROFILE\Downloads\Hardware_List.csv"
$OutputPath = Read-Host "Save to (press Enter for $default)"
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $default }

Get-VmsHardware -Verbose | Select-Object Enabled, Name, DisplayName, Address, $macProperty, $SerialNumber, Model, UserName, $Password, $Firmware, Guid, ParentItemPath, LastModified, Description | Export-Csv $OutputPath -NoTypeInformation
Write-Host "Exported to: $OutputPath" -ForegroundColor Green