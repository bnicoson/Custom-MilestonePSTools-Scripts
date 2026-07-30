# Add-CamerasFromCsv

Batch-add cameras to Milestone XProtect from a CSV, configure them, and produce a documentation report — taking the bulk of the manual work out of onboarding a site's worth of cameras.

## Files

| File | Purpose |
|---|---|
| `Add-CamerasFromCsv.ps1` | The main script. |
| `Add-CamerasFromCsv-Template.csv` | Fill-in-the-blanks template (all columns). |
| `Test-AddCamerasEnvironment.ps1` | Optional **read-only** probe to confirm cmdlets / stream keys / report columns on a given system before relying on the script. Changes nothing. |

## Requirements

- **Windows PowerShell 5.1** — MilestonePSTools does **not** load under PowerShell 7 (pwsh). The script stops with a clear message if run under 7. From a pwsh terminal, launch it with `powershell.exe`.
- MilestonePSTools installed, and permission to add hardware to the target VMS.
- Cameras must be **online and reachable** by the recording server at add time.

## How to run

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Add-CamerasFromCsv.ps1" -CsvPath ".\my-cameras.csv"
```

Optional parameters:

- `-ReportPath <path>` — where to write the documentation CSV (default: `~\Downloads\AddedCameras_<timestamp>.csv`).
- `-ImportGroupPath <path>` — the device group every camera is guaranteed to join (default: `/Imported from CSV`).
- `-SkipEnableAllChannels` — testing aid; leaves channels exactly as Import set them (see "Multisensors").

At runtime you'll get: the login dialog, a credential prompt if any row omits user/pass, a recording-server picker only if a row is blank *and* the site has more than one recorder, and one-time Zipstream / compression prompts.

## CSV columns

Header row required; matching is case-insensitive. Only **IP** is mandatory.

| Column | Blank behavior |
|---|---|
| `IP` | *(required)* |
| `Name` | Milestone default name; if set, hardware/camera(s) named `IP - Name` |
| `Username` / `Password` | Prompts once for a fallback credential (plain text in the sheet — see Security) |
| `Driver` | Number (e.g. `806`) or a driver name; blank/unmatched → **Axis auto-detect** |
| `Port` | `80` |
| `RecordingServer` | Auto if one recorder; else pick at runtime. Pick **multiple** to split blank rows round-robin |
| `FPS` | `8` |
| `MotionDetection` | `Yes` (enabled) |
| `MotionThreshold` | `200` (raw pixel count — NOT the 0–100 Management Client number) |
| `DeviceGroup` | none; semicolon-delimited paths (e.g. `/Site A;/Site A/Warehouse`), added on top of the import folder, created if missing |

## What it does to every added camera

- Names the hardware, every enabled camera channel, and the metadata device.
- **Enables all camera channels** so multisensor lenses aren't left disabled (Import only enables channel 0 by default). On single-sensor Axis cams this also enables view-area channels — see the flag below.
- Enables the metadata device.
- Applies FPS and motion detection (from the CSV, with defaults).
- Applies compression and Axis Zipstream if you answered the prompts.
- Adds every camera to `/Imported from CSV` **and** any `DeviceGroup` paths.
- Flags 360 / multi-view cameras (model keyword or >1 enabled channel) for review.
- Writes a documentation report (firmware, MAC, model, codec/res/FPS, motion, groups, etc.) to GridView + CSV.

## Not run-and-forget

The script prints a reminder at the end. On **each** camera you still need to:

1. Review motion-detection **exclusion regions** (the script sets none).
2. Verify the **correct streams are recording** at the intended resolution.
3. On flagged 360 / multi-view cameras, **disable the extra views** you don't want recording (e.g. an Axis dome's view-area channel, or a multisensor's combined/overview channel).

## Security

Passwords are plain text in the CSV, and the script writes a temporary import CSV (also plain text) whose path it prints. Keep these files somewhere safe and delete them when done.

## Notes / gotchas learned building this

- `Import-VmsHardware` enables only channel 0 by default — hence the force-enable-all-channels step.
- The metadata cmdlet is `Get-VmsMetadata` / `Set-VmsMetadata` (the older `Get-Metadata` doesn't exist in current module versions).
- Milestone config objects go **stale after `.Save()`** — re-fetch before reusing.
- `Add-VmsDeviceGroupMember` is all-or-nothing: it errors and adds nothing if any device is already a group member (handled with a per-camera fallback).
