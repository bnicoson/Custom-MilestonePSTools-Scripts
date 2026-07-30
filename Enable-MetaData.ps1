if ($PSVersionTable.PSEdition -eq 'Core') {
    throw "Run this in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh). MilestonePSTools requires .NET Framework."
}

Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# Get-VmsMetadata with -EnableFilter All so disabled metadata devices are returned too.
# (The old 'Get-Metadata' cmdlet does not exist in current module versions.)
Get-VmsMetadata -EnableFilter All | Where-Object Enabled -eq $false | ForEach-Object {
    Write-Host "Enabling metadata on: $($_.Name)" -ForegroundColor Cyan
    Set-VmsMetadata -InputObject $_ -Enabled $true | Out-Null
}

Write-Host "Done." -ForegroundColor Green
