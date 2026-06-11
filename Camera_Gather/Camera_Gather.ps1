<#
.SYNOPSIS
    Connects to multiple Milestone servers and exports camera and hardware reports for each.

.DESCRIPTION
    Reads a list of server IP addresses or hostnames from Servers.txt (one per line),
    connects to each, and exports two CSVs per server into a Lists\ subfolder:
      - <server>_Cameras_List.csv
      - <server>_Hardware_List.csv

.NOTES
    Requires MilestonePSTools module: Install-Module MilestonePSTools -Scope CurrentUser

    SETUP: Create a Servers.txt file in the same folder as this script with one server
    IP address or hostname per line. Example:
        192.168.1.100
        192.168.1.101
        vms-server.example.com

    Servers.txt is excluded from source control — do not commit it.
#>

# Define the path to the Servers.txt file
$serversFile = "Servers.txt"

# Check if the file exists
if (Test-Path $serversFile) {
    # Read all lines from the file
    $servers = Get-Content -Path $serversFile

    # Iterate through each IP address in the file
    if (-not (Test-Path "Lists")) {
        New-Item -ItemType Directory -Path "Lists" | Out-Null
    }

    foreach ($server in $servers) {
        Write-Host "Processing server: $server" -ForegroundColor Cyan
        $connectionParams = @{
            ServerAddress = "http://${server}//"
            AcceptEula    = $true
            ErrorAction   = 'Stop'
        }
        try {
            Connect-Vms @connectionParams
            Get-VmsCameraReport -Verbose | Export-Csv "Lists\${server}_Cameras_List.csv" -NoTypeInformation
            Get-VmsHardware -Verbose     | Export-Csv "Lists\${server}_Hardware_List.csv" -NoTypeInformation
            Disconnect-Vms
            Write-Host "  Done: $server" -ForegroundColor Green
        }
        catch {
            Write-Warning "  Failed to process $server - $_"
        }
    }
} else {
    Write-Error "The file $serversFile does not exist."
}