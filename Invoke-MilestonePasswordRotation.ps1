<#
.SYNOPSIS
    Rotates camera passwords in Milestone XProtect.

.DESCRIPTION
    Three modes:
      1. Single password - applies one password to all recorders and devices.
      2. Per-recorder   - prompts for a different password per recording server.
      3. Retry failures - re-runs failed devices from a previous rotation report CSV.

    Output CSVs are written to C:\Tools\PasswordRotationReports.

.NOTES
    Requires MilestonePSTools module: Install-Module MilestonePSTools -Scope CurrentUser
#>

# -----------------------------------------------
# IMPORT MODULE
# -----------------------------------------------
Import-Module MilestonePSTools -ErrorAction Stop

# -----------------------------------------------
# CONNECT
# -----------------------------------------------
Connect-ManagementServer -ShowDialog -AcceptEula -Force

# -----------------------------------------------
# OUTPUT FOLDER
# -----------------------------------------------
$defaultFolder = "$env:USERPROFILE\Downloads\PasswordRotationReports"
$OutputFolder  = Read-Host "Output folder (press Enter for $defaultFolder)"
if ([string]::IsNullOrWhiteSpace($OutputFolder)) { $OutputFolder = $defaultFolder }
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}
$Timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'

# -----------------------------------------------
# HELPER: rotate all hardware on a single recorder
# -----------------------------------------------
function Invoke-RecorderRotation {
    param(
        [Parameter(Mandatory)] $Recorder,
        [Parameter(Mandatory)] [System.Security.SecureString] $Password
    )

    if ($Password.Length -eq 0) {
        Write-Host "Skipping $($Recorder.Name)" -ForegroundColor Gray
        return
    }

    Write-Host "Recording Server: $($Recorder.Name)" -ForegroundColor Yellow

    $HardwareList = Get-VmsHardware -RecordingServer $Recorder

    if ($HardwareList.Count -eq 0) {
        Write-Host "  No hardware found. Skipping.`n" -ForegroundColor Gray
        return
    }

    Write-Host "  Found $($HardwareList.Count) device(s). Rotating passwords..." -ForegroundColor Cyan

    $Report = [System.Collections.Generic.List[PSCustomObject]]::new()
    $j = 0

    foreach ($HW in $HardwareList) {
        $j++
        Write-Progress -Activity "Rotating passwords on $($Recorder.Name)" `
            -Status $HW.Name `
            -PercentComplete (($j / $HardwareList.Count) * 100)

        $Row = [ordered]@{
            HardwareDevice  = $HW.Name
            Model           = $HW.Model
            Address         = $HW.Address
            RecordingServer = $Recorder.Name
            Status          = ''
            Reason          = ''
        }

        try {
            $HW | Set-VmsHardware -Password $Password -UpdateRemoteHardware -ErrorAction Stop
            $Row.Status = 'Success'
        }
        catch {
            $Row.Status = 'Failed'
            $Row.Reason = $_.Exception.Message
        }

        $Report.Add([PSCustomObject]$Row)
    }

    Write-Progress -Activity "Rotating passwords on $($Recorder.Name)" -Completed

    $SafeName = $Recorder.Name -replace '[\\/:*?"<>|]', '_'
    $CsvPath  = Join-Path $OutputFolder "$Timestamp`_$SafeName.csv"
    $Report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    $SuccessCount = ($Report | Where-Object { $_.Status -eq 'Success' }).Count
    $FailCount    = ($Report | Where-Object { $_.Status -eq 'Failed'  }).Count

    Write-Host "  Complete -- Success: $SuccessCount | Failed: $FailCount" -ForegroundColor Green
    Write-Host "  Report: $CsvPath`n" -ForegroundColor Gray
}

# -----------------------------------------------
# MODE SELECTION
# -----------------------------------------------
Write-Host "`nSelect rotation mode:" -ForegroundColor Cyan
Write-Host "  [1] Single password - same password for every device on every recorder"
Write-Host "  [2] Per-recorder    - different password per recording server"
Write-Host "  [3] Retry failures  - re-run failed devices from a previous report CSV"
Write-Host ""

do {
    $Choice = Read-Host "Choice (1, 2, or 3)"
} while ($Choice -notin @('1', '2', '3'))

switch ($Choice) {

    # -----------------------------------------------
    # MODE 1: SINGLE PASSWORD
    # -----------------------------------------------
    '1' {
        $NewPassword = Read-Host -Prompt "`nPassword to apply to ALL recording servers" -AsSecureString
        if ($NewPassword.Length -eq 0) {
            Write-Host "No password entered. Exiting." -ForegroundColor Red
            exit
        }

        Write-Host "`nRetrieving recording servers..." -ForegroundColor Cyan
        $Recorders = @(Get-VmsRecordingServer)
        Write-Host "Found $($Recorders.Count) recording server(s).`n" -ForegroundColor Green

        foreach ($Recorder in $Recorders) {
            Invoke-RecorderRotation -Recorder $Recorder -Password $NewPassword
        }
    }

    # -----------------------------------------------
    # MODE 2: PER-RECORDER PASSWORDS
    # -----------------------------------------------
    '2' {
        Write-Host "`nRetrieving recording servers..." -ForegroundColor Cyan
        $Recorders = @(Get-VmsRecordingServer)
        Write-Host "Found $($Recorders.Count) recording server(s).`n" -ForegroundColor Green

        $Passwords = New-Object 'System.Security.SecureString[]' $Recorders.Count
        Write-Host "Enter a password for each recorder (leave blank to skip):`n" -ForegroundColor Cyan
        for ($i = 0; $i -lt $Recorders.Count; $i++) {
            $Passwords[$i] = Read-Host -Prompt "  $($Recorders[$i].Name)" -AsSecureString
        }
        Write-Host ""

        for ($i = 0; $i -lt $Recorders.Count; $i++) {
            Invoke-RecorderRotation -Recorder $Recorders[$i] -Password $Passwords[$i]
        }
    }

    # -----------------------------------------------
    # MODE 3: RETRY FROM FAILURE REPORT
    # -----------------------------------------------
    '3' {
        $ReportPath = Read-Host "`nPath to failure report CSV"
        if (-not (Test-Path $ReportPath)) {
            Write-Host "File not found: $ReportPath" -ForegroundColor Red
            exit
        }

        $Failures = Import-Csv $ReportPath | Where-Object {
            $_.FailureType -notin @('Tyco - No Password Support', 'Offline / No Access')
        }

        if ($Failures.Count -eq 0) {
            Write-Host "No actionable failures found (Tyco and Offline entries are skipped)." -ForegroundColor Yellow
            exit
        }

        $Groups = $Failures | Group-Object FailureType
        Write-Host "`nActionable failures:" -ForegroundColor Cyan
        foreach ($g in $Groups) {
            Write-Host "  $($g.Name): $($g.Count) device(s)"
        }
        Write-Host ""

        $Passwords = @{}
        foreach ($g in $Groups) {
            $Passwords[$g.Name] = Read-Host -Prompt "Password for '$($g.Name)' devices (Enter to skip)" -AsSecureString
        }
        Write-Host ""

        Write-Host "Retrieving recording servers and hardware..." -ForegroundColor Cyan
        $Recorders = @(Get-VmsRecordingServer)
        $HardwareCache = @{}
        foreach ($Rec in $Recorders) {
            $HardwareCache[$Rec.Name] = @(Get-VmsHardware -RecordingServer $Rec)
        }

        $Report = [System.Collections.Generic.List[PSCustomObject]]::new()
        $Total  = $Failures.Count
        $i      = 0

        foreach ($Row in $Failures) {
            $i++
            $Pw = $Passwords[$Row.FailureType]

            if ($null -eq $Pw -or $Pw.Length -eq 0) {
                Write-Host "  Skipping $($Row.HardwareDevice) (no password for '$($Row.FailureType)')" -ForegroundColor Gray
                continue
            }

            Write-Progress -Activity "Retrying failed devices" `
                -Status "$($Row.HardwareDevice) ($($Row.RecordingServer))" `
                -PercentComplete (($i / $Total) * 100)

            $HW = $HardwareCache[$Row.RecordingServer] |
                  Where-Object { $_.Address -eq $Row.Address } |
                  Select-Object -First 1

            $ResultRow = [ordered]@{
                FailureType     = $Row.FailureType
                HardwareDevice  = $Row.HardwareDevice
                Model           = $Row.Model
                Address         = $Row.Address
                RecordingServer = $Row.RecordingServer
                Status          = ''
                Reason          = ''
            }

            if ($null -eq $HW) {
                $ResultRow.Status = 'Failed'
                $ResultRow.Reason = 'Hardware not found on recording server'
            }
            else {
                try {
                    $HW | Set-VmsHardware -Password $Pw -UpdateRemoteHardware -ErrorAction Stop
                    $ResultRow.Status = 'Success'
                }
                catch {
                    $ResultRow.Status = 'Failed'
                    $ResultRow.Reason = $_.Exception.Message
                }
            }

            $Report.Add([PSCustomObject]$ResultRow)
        }

        Write-Progress -Activity "Retrying failed devices" -Completed

        $CsvPath = Join-Path $OutputFolder "$Timestamp`_RetryReport.csv"
        $Report | Sort-Object FailureType, RecordingServer, HardwareDevice |
            Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

        $SuccessCount = ($Report | Where-Object { $_.Status -eq 'Success' }).Count
        $FailCount    = ($Report | Where-Object { $_.Status -eq 'Failed'  }).Count

        Write-Host "Done -- Success: $SuccessCount | Failed: $FailCount" -ForegroundColor Green
        Write-Host "Report: $CsvPath" -ForegroundColor Gray
    }
}

Write-Host "`nAll done." -ForegroundColor Green
