Import-Module MilestonePSTools -ErrorAction Stop
Connect-ManagementServer -ShowDialog -AcceptEula

$daysInput = Read-Host "How many days back to export (press Enter for 3)"
$days = if ([string]::IsNullOrWhiteSpace($daysInput)) { 3 } else { [int]$daysInput }

$StartTime = (Get-Date).Date.AddDays(-$days)
$EndTime   = (Get-Date).Date.AddDays(1)

$defaultFolder = "$env:USERPROFILE\Downloads"
$OutputFolder  = Read-Host "Save folder (press Enter for $defaultFolder)"
if ([string]::IsNullOrWhiteSpace($OutputFolder)) { $OutputFolder = $defaultFolder }
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

Get-VmsLog -LogType Audit  -StartTime $StartTime -EndTime $EndTime | Export-Csv "$OutputFolder\VMS_Audit_Log_$timestamp.csv"  -NoTypeInformation
Get-VmsLog -LogType System -StartTime $StartTime -EndTime $EndTime | Export-Csv "$OutputFolder\VMS_System_Log_$timestamp.csv" -NoTypeInformation
Get-VmsLog -LogType Rules  -StartTime $StartTime -EndTime $EndTime | Export-Csv "$OutputFolder\VMS_Rules_Log_$timestamp.csv"  -NoTypeInformation

Write-Host "Logs exported to: $OutputFolder" -ForegroundColor Green
