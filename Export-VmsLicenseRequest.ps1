Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula -Force

$OutputPath = "$env:USERPROFILE\Downloads\license.lrq"
Export-VmsLicenseRequest -Path $OutputPath -Force
Write-Host "License request exported to: $OutputPath" -ForegroundColor Green
