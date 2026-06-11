<#
.SYNOPSIS
    Pulls all Milestone cameras and their associated roles/permissions and exports to CSV.

.DESCRIPTION
    Connects to a Milestone XProtect Management Server, retrieves all cameras,
    all roles, role members, and overall security permissions for cameras,
    then exports a full report to CSV.

.NOTES
    Requires MilestonePSTools module: Install-Module MilestonePSTools
    Run: Install-Module MilestonePSTools -Scope CurrentUser
#>

# -----------------------------------------------
# IMPORT MODULE
# -----------------------------------------------
Import-Module MilestonePSTools -ErrorAction Stop

# -----------------------------------------------
# CONFIG
# -----------------------------------------------
$OutputPath = "$env:USERPROFILE\Downloads\Milestone-Camera-Roles-$(Get-Date -Format 'yyyy-MM-dd').csv"

# -----------------------------------------------
# CONNECT
# -----------------------------------------------
Write-Host "Connecting to Milestone Management Server..." -ForegroundColor Cyan
Connect-ManagementServer -ShowDialog -AcceptEula -Force
Write-Host "Connected." -ForegroundColor Green

# -----------------------------------------------
# GET DATA
# -----------------------------------------------
Write-Host "Retrieving cameras..." -ForegroundColor Cyan
$cameras = Get-VmsCamera -EnableFilter Enabled

Write-Host "Retrieving roles..." -ForegroundColor Cyan
$roles = Get-VmsRole

# Build lookup: RoleId -> Members
Write-Host "Retrieving role members..." -ForegroundColor Cyan
$roleMemberMap = @{}
foreach ($role in $roles) {
    $members = Get-VmsRoleMember -Role $role
    $roleMemberMap[$role.Id] = if ($members) {
        ($members | ForEach-Object { $_.AccountName }) -join "; "
    } else { "(no members)" }
}

# Pre-fetch all ACLs: one call per camera/role combination
Write-Host "Retrieving device ACLs..." -ForegroundColor Cyan
$aclMap = @{}
$total  = $cameras.Count * $roles.Count
$count  = 0
foreach ($role in $roles) {
    $aclMap[$role.Id] = @{}
    foreach ($camera in $cameras) {
        $count++
        Write-Progress -Activity "Retrieving ACLs" -Status "$count of $total" -PercentComplete (($count / $total) * 100)
        try {
            $aclMap[$role.Id][$camera.Id] = Get-DeviceAcl -Camera $camera -Role $role -ErrorAction SilentlyContinue
        } catch {
            $aclMap[$role.Id][$camera.Id] = $null
        }
    }
}
Write-Progress -Activity "Retrieving ACLs" -Completed

# -----------------------------------------------
# BUILD REPORT - one row per camera, one column per role
# -----------------------------------------------
Write-Host "Building camera-role report..." -ForegroundColor Cyan
$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($camera in $cameras) {
    $row = [ordered]@{
        CameraName    = $camera.Name
        CameraEnabled = $camera.Enabled
        CameraId      = $camera.Id
    }

    foreach ($role in $roles) {
        $row["$($role.Name) - Members"] = $roleMemberMap[$role.Id]

        $acl = $aclMap[$role.Id][$camera.Id]
        if ($acl -and $acl.SecurityAttributes) {
            $filterKeys = $acl.SecurityAttributes.Keys | Where-Object { $_ -eq 'GENERIC_READ' -or $_ -eq 'VIEW_LIVE' -or $_ -like 'PLAYBACK*' -or $_ -eq 'EXPORT' -or $_ -like 'DELETE_*' }
            foreach ($key in $filterKeys) {
                $row["$($role.Name) - $key"] = $acl.SecurityAttributes[$key]
            }
        } else {
            $row["$($role.Name) - Access"] = "None"
        }
    }

    $report.Add([PSCustomObject]$row)
}

# -----------------------------------------------
# EXPORT
# -----------------------------------------------
Write-Host "Exporting report to $OutputPath..." -ForegroundColor Cyan
$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Done! $($report.Count) rows exported to:" -ForegroundColor Green
Write-Host $OutputPath -ForegroundColor Yellow
