param(
    [string]$Folder = $PSScriptRoot
)

$OutFile  = Join-Path $Folder 'PasswordRotation_Failures.csv'

$CsvFiles = Get-ChildItem -Path $Folder -Filter '*.csv' |
            Where-Object { $_.Name -ne 'PasswordRotation_Failures.csv' }

$AllFailed = foreach ($file in $CsvFiles) {
    Import-Csv $file.FullName | Where-Object { $_.Status -eq 'Failed' }
}

$Result = foreach ($row in $AllFailed) {
    $failureType = switch -Regex ($row.Reason) {
        'VMO66016'              { 'Offline / No Access' }
        'VMO66004.*Tyco'        { 'Tyco - No Password Support' }
        'VMO66004'              { 'MicroView - Manual Required' }
        'VMO66035'              { 'Hanwha - Password Length' }
        'VMO66013'              { 'Unknown Server Error' }
        default                 { 'Other' }
    }

    [PSCustomObject][ordered]@{
        FailureType     = $failureType
        RecordingServer = $row.RecordingServer
        HardwareDevice  = $row.HardwareDevice
        Model           = $row.Model
        Address         = $row.Address
        Reason          = $row.Reason
    }
}

$Result |
    Sort-Object FailureType, RecordingServer, HardwareDevice |
    Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

Write-Host "Done. $($Result.Count) failed devices written to:" -ForegroundColor Green
Write-Host "  $OutFile" -ForegroundColor Gray

# Summary
$Result | Group-Object FailureType | Sort-Object Name | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)"
}
