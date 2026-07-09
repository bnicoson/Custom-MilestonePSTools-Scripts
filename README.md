# Custom MilestonePSTools Scripts

PowerShell scripts for managing Milestone XProtect VMS systems, built on the [MilestonePSTools](https://www.milestonepstools.com/) module by Josh Hendricks.

## Requirements

- PowerShell 5.1+
- MilestonePSTools module: `Install-Module MilestonePSTools -Scope CurrentUser`
- Most scripts connect via a dialog on launch - no hardcoded credentials

---

## Password Rotation Workflow

Three scripts work together for rotating camera passwords across a site:

1. Run `Invoke-MilestonePasswordRotation.ps1` (mode 1 or 2) to rotate passwords across all recorders. Each recorder gets its own output CSV.
2. Drop all the output CSVs into one folder and run `Make-FailureReport.ps1` against that folder. It consolidates every failure into a single report, grouped by failure type (Hanwha, MicroView, Offline, etc.).
3. Run `Invoke-MilestonePasswordRotation.ps1` again (mode 3) and point it at the failure report to retry only the devices that didn't take the first time.

---

## Scripts

### Password Management
| Script | Description |
|---|---|
| `Invoke-MilestonePasswordRotation.ps1` | Rotate camera passwords - single password, per-recorder, or retry failures from a previous report |
| `Make-FailureReport.ps1` | Consolidates per-recorder rotation CSVs into a single categorized failure report |

### Reporting
| Script | Description |
|---|---|
| `Get-MilestoneUserCameraAccess.ps1` | Lists all cameras a specific user can access, with per-role permissions |
| `Get-MilestoneCameraRoles.ps1` | Exports all cameras and their role/permission assignments |
| `Get-VMSCameraReport.ps1` | Exports a full camera list to CSV |
| `Get-CameraStorageByServer.ps1` | Per-camera recording storage used - select one or more recording servers, view in GridView (sortable by driver), optional CSV export |
| `Get-CameraSettingsReport.ps1` | Per-camera stream + motion settings (codec, resolution, FPS, bitrate/compression, GOP, Axis Zipstream, motion threshold/sensitivity) across selected servers, with a catch-all column for driver-specific keys; GridView + optional CSV export |
| `Get-VMSHardware.ps1` | Exports a hardware list to CSV |
| `Find-Device.ps1` | Locate hardware/cameras across selected recording servers by name, IP, MAC, or serial (partial matches); shows parent hardware, recorder, address, MAC, serial, model, and camera channels. GridView + optional CSV |
| `Custom-Hardware-Report.ps1` | Extended hardware report including firmware, MAC, serial, and password - **output CSV contains passwords, handle accordingly** |
| `Device-Status.ps1` | Exports camera device status to CSV |
| `Get-VMSLog_to_CSV.ps1` | Exports audit, system, and rules logs to CSV |
| `Export-VmsLicenseRequest.ps1` | Exports a license request file to Downloads |

### Hardware / Driver Management
| Script | Description |
|---|---|
| `Mass-Hardware-Replace.ps1` | Auto-replaces drivers on all hardware |
| `Selective-Hardware-Replace.ps1` | Select hardware via GridView, then pick the replacement driver |
| `Hardware_Replace_By_Server.ps1` | Auto-replaces drivers per recording server (GridView server selection) |
| `MassSelectDriver.ps1` | Select hardware via GridView and apply a specific driver |
| `Get-DriverGuids.ps1` | Select a recording server, then list all available drivers with their GUIDs, numbers, and versions |
| `Find-HardwareByDriver.ps1` | Select a recording server and list all hardware on it using a specific driver number |

### Camera Configuration
| Script | Description |
|---|---|
| `Set-CameraStreamSettings.ps1` | Bulk-apply stream settings (FPS, resolution, codec, compression, Axis Zipstream) and motion settings across GridView-selected cameras on one or more recording servers. Menu is built from the first Axis camera and offers only each setting's valid values; includes a "highest resolution per camera" option. Preview, confirm, change log + optional CSV |

### Storage
| Script | Description |
|---|---|
| `Set-CameraStorage.ps1` | Select a recording server, pick cameras via GridView, pick a target storage via GridView, then reassign those cameras to it (existing recordings stay in the old storage and age out) |

### HTTPS Configuration
| Script | Description |
|---|---|
| `Enable-HTTPS-Per-Recorder.ps1` | Enable or disable HTTPS on cameras, scoped to selected recording servers |
| `Enable-HTTPS-All-Cams.ps1` | Enable HTTPS on all cameras at once |

### Metadata
| Script | Description |
|---|---|
| `Enable-MetaData.ps1` | Enables metadata on all hardware that currently has it disabled |

### Camera Groups
| Script | Description |
|---|---|
| `Group-CamerasByModel.ps1` | Function - groups cameras by make/model into VMS device groups |

### Multi-Server Gather
| Script | Description |
|---|---|
| `Camera_Gather/Camera_Gather.ps1` | Connects to a list of servers and exports camera + hardware CSVs for each |

> **Setup:** Create a `Servers.txt` file in the `Camera_Gather` folder with one server IP or hostname per line. This file is excluded from source control.

### Log Monitoring
| Script | Description |
|---|---|
| `XProtect-Installer-Log-Live.ps1` | Live tail of the XProtect installer log |
| `Device-Pack-Installer-Log-Live.ps1` | Live tail of the device pack driver scan log |

### Module Management
| Script | Description |
|---|---|
| `Install-MilestonePSTools.ps1` | Installs the MilestonePSTools module |
| `Update-MilestonePSTools.ps1` | Updates the MilestonePSTools module to the latest version |
