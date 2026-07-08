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
# Build a GUID -> recording server name lookup so we can show the actual server name.
$recorderByGuid = @{}
Get-VmsRecordingServer | ForEach-Object { $recorderByGuid[$_.Id.ToString().ToLower()] = $_.Name }
$RecordingServer = @{
    Name       = 'RecordingServer'
    Expression = {
        if ($_.ParentItemPath -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $g = $Matches[1].ToLower()
            if ($recorderByGuid.ContainsKey($g)) { $recorderByGuid[$g] } else { $_.ParentItemPath }
        } else { $_.ParentItemPath }
    }
}
$default = "$env:USERPROFILE\Downloads\Hardware_List.csv"
$OutputPath = Read-Host "Save to (press Enter for $default)"
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $default }

Get-VmsHardware -Verbose | Select-Object Enabled, Name, DisplayName, Address, $macProperty, $SerialNumber, Model, UserName, $Password, $Firmware, Guid, $RecordingServer, ParentItemPath, LastModified, Description | Export-Csv $OutputPath -NoTypeInformation
Write-Host "Exported to: $OutputPath" -ForegroundColor Green