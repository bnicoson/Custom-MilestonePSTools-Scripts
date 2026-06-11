Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force

Get-VmsHardware | Get-Metadata | Where-Object Enabled -eq $false | ForEach-Object {
    Write-Host "Enabling metadata on: $($_.Name)" -ForegroundColor Cyan
    $_.Enabled = $true
    $_.Save()
}

Write-Host "Done." -ForegroundColor Green
