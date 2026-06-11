<#
.SYNOPSIS
    Lists all cameras a specific user has access to, along with their permissions.

.DESCRIPTION
    Connects to a Milestone XProtect Management Server, prompts for a username,
    finds all roles that user belongs to, then retrieves per-camera permissions
    for each of those roles and exports to CSV.

.NOTES
    Requires MilestonePSTools module: Install-Module MilestonePSTools -Scope CurrentUser
#>

# -----------------------------------------------
# IMPORT MODULE
# -----------------------------------------------
Import-Module MilestonePSTools -ErrorAction Stop

# -----------------------------------------------
# CONFIG
# -----------------------------------------------
$OutputPath = "$env:USERPROFILE\Downloads\Milestone-User-Access-$(Get-Date -Format 'yyyy-MM-dd').csv"

# -----------------------------------------------
# CONNECT
# -----------------------------------------------
Write-Host "Connecting to Milestone Management Server..." -ForegroundColor Cyan
Connect-ManagementServer -ShowDialog -AcceptEula -Force
Write-Host "Connected." -ForegroundColor Green

# -----------------------------------------------
# GET USERNAME
# -----------------------------------------------
$Username = Read-Host "Enter username to look up (full or partial, e.g. DOMAIN\jsmith or jsmith)"

# -----------------------------------------------
# FIND ROLES FOR USER
# -----------------------------------------------
Write-Host "Searching roles for '$Username'..." -ForegroundColor Cyan
$roles = Get-VmsRole
$userRoles = @()

foreach ($role in $roles) {
    $members = Get-VmsRoleMember -Role $role
    $match = $members | Where-Object { $_.AccountName -like "*$Username*" }
    if ($match) {
        $userRoles += [PSCustomObject]@{
            Role          = $role
            AccountName   = ($match | ForEach-Object { $_.AccountName }) -join "; "
        }
    }
}

if ($userRoles.Count -eq 0) {
    Write-Warning "No roles found matching '$Username'. Check the username and try again."
    exit
}

# Check if user is in the Administrators role (exempt from device ACLs - has full access)
$isAdmin = $userRoles | Where-Object { $_.Role.RoleType -eq 'Administrators' -or $_.Role.Name -eq 'Administrators' }

Write-Host "Found $($userRoles.Count) role(s) for '$Username':" -ForegroundColor Green
$userRoles | ForEach-Object { Write-Host "  - $($_.Role.Name)  [$($_.AccountName)]" -ForegroundColor Green }

if ($isAdmin) {
    Write-Warning "This user is a member of the Administrators role and has full access to all cameras. The report below reflects only additional role-based permissions."
}

# -----------------------------------------------
# GET CAMERAS
# -----------------------------------------------
Write-Host "Retrieving cameras..." -ForegroundColor Cyan
$cameras = Get-VmsCamera -EnableFilter All

# -----------------------------------------------
# RETRIEVE ACLs
# -----------------------------------------------
Write-Host "Retrieving device ACLs..." -ForegroundColor Cyan
$aclMap = @{}
$total  = $cameras.Count * $userRoles.Count
$count  = 0

foreach ($entry in $userRoles) {
    $aclMap[$entry.Role.Id] = @{}
    foreach ($camera in $cameras) {
        $count++
        Write-Progress -Activity "Retrieving ACLs" -Status "$count of $total" -PercentComplete (($count / $total) * 100)
        try {
            $aclMap[$entry.Role.Id][$camera.Id] = Get-DeviceAcl -Camera $camera -Role $entry.Role -ErrorAction SilentlyContinue
        } catch {
            $aclMap[$entry.Role.Id][$camera.Id] = $null
        }
    }
}
Write-Progress -Activity "Retrieving ACLs" -Completed

# -----------------------------------------------
# BUILD REPORT - one row per camera per role
# -----------------------------------------------
Write-Host "Building report..." -ForegroundColor Cyan
$report = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($camera in $cameras) {
    foreach ($entry in $userRoles) {
        $acl = $aclMap[$entry.Role.Id][$camera.Id]

        if ($acl -and $acl.SecurityAttributes) {
            $filterKeys = $acl.SecurityAttributes.Keys | Where-Object {
                $_ -eq 'GENERIC_READ' -or $_ -eq 'VIEW_LIVE' -or $_ -like 'PLAYBACK*' -or $_ -eq 'EXPORT' -or $_ -like 'DELETE_*'
            }

            # Only include cameras where at least one permission is True
            $hasAccess = $filterKeys | Where-Object { $acl.SecurityAttributes[$_] -eq $true }
            if (-not $hasAccess) { continue }

            $row = [ordered]@{
                CameraName      = $camera.Name
                CameraEnabled   = $camera.Enabled
                CameraId        = $camera.Id
                RoleName        = $entry.Role.Name
                AccountName     = $entry.AccountName
                IsAdministrator = [bool]$isAdmin
            }

            foreach ($key in $filterKeys) {
                $row[$key] = $acl.SecurityAttributes[$key]
            }

            $report.Add([PSCustomObject]$row)
        }
    }
}

# -----------------------------------------------
# EXPORT
# -----------------------------------------------
if ($report.Count -eq 0) {
    Write-Warning "No camera access found for '$Username'."
} else {
    Write-Host "Exporting report to $OutputPath..." -ForegroundColor Cyan
    $report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Done! $($report.Count) rows exported to:" -ForegroundColor Green
    Write-Host $OutputPath -ForegroundColor Yellow
}
