# Admin Hub

An administrative PowerShell profile for Windows Servers. When deployed to the
**AllUsersAllHosts** profile location, every user who opens PowerShell on the
server is greeted with a banner and an interactive menu of common
administrative tasks — with the option to drop to a normal shell at any time.

```
    _    ____  __  __ ___ _   _
   / \  |  _ \|  \/  |_ _| \ | |
  / _ \ | | | | |\/| || ||  \| |
 / ___ \| |_| | |  | || || |\  |
/_/   \_\____/|_|  |_|___|_| \_|
 _   _ _   _ ____
| | | | | | | __ )
| |_| | | | |  _ \
|  _  | |_| | |_) |
|_| |_|\___/|____/
Server Administration Console
```

## Screenshots

The menu shown at startup:

```text
============================================================
  SERVER ADMIN MENU  -  SRV-DB01
============================================================
  [1]  Disk Space
  [2]  Top Resource Users (live)
  [3]  Restart a Service
  [4]  Pending Windows Updates
  [5]  Full System Health Check
  [M]  Top 10 Memory Usage
  [S]  Top 10 Swap/Page File
  [A]  Active User Sessions
  [C]  Disk Cleanup (C: drive)
  [E]  Export Health Report
  [0]  Exit to Shell
============================================================
  Tip: after a task, press [X] then Enter to exit - type Show-AdminMenu to reopen.

> Select an option
```

Output of **Export Health Report** `[E]` — the pass/fail summary printed on
screen before the full report is written to disk:

```text
============================================================
  Health Summary - SRV-DB01
============================================================
  [FAIL] Disk space           highest used: E: 92%
  [WARN] Pending reboot        Windows Update
  [FAIL] RAID/disk (iDRAC)     Disk.Bay.3 Status=Failed; PredictiveFailure=Active
  [WARN] Auto services         2 stopped (Spooler, wuauserv)
  [OK  ] Memory                63% used
  [WARN] Pagefile              82% used
  [WARN] System errors (24h)   4 error event(s)
  [OK  ] Uptime                21d 7h since last boot

  Overall: FAIL
  Report saved to: C:\AdminReports\HealthReport_SRV-DB01_20260626_143052.txt
  Size: 9.7 KB
```

> Output is color-coded in the console (green/yellow/red); GitHub renders these
> samples in monochrome. To add a real color screenshot, capture your PowerShell
> window and drop a PNG in `AdminHub/images/`, then reference it here.

## Menu options

| Key | Option                      | Type        |
|-----|-----------------------------|-------------|
| 1   | Disk Space                  | Read        |
| 2   | Top Resource Users (live)   | Read        |
| 3   | Restart a Service           | Action      |
| 4   | Pending Windows Updates     | Action      |
| 5   | Full System Health Check    | Read        |
| M   | Top 10 Memory Usage         | Read        |
| S   | Top 10 Swap / Page File     | Read        |
| A   | Active User Sessions        | Read        |
| C   | Disk Cleanup (C: drive)     | Destructive |
| E   | Export Health Report        | Action      |
| 0   | Exit to Shell               | —           |

After any task runs, you get a `[Enter] Return to menu / [X] Exit to shell`
prompt so output stays on screen — press `X` then Enter to drop to the shell.
Exiting leaves all task functions loaded in the session; type `Show-AdminMenu`
at any time to reopen the menu. The menu also shows this tip on screen each time
it is drawn.

### Health checks

Both **Full System Health Check** `[5]` and **Export Health Report** `[E]` run a
set of pass/fail checks and print a summary verdict (`OK` / `WARN` / `FAIL`) per
item, plus an overall status:

- **Disk space** — flags the busiest fixed drive (WARN ≥ 80%, FAIL ≥ 90%)
- **Pending reboot** — CBS, Windows Update, pending file/computer rename
- **Disk health** — on Dell hardware with local `racadm` installed, queries the
  iDRAC (`racadm storage get pdisks/vdisks`) and flags any disk that is not `Ok`
  or shows a predictive-failure state (reported as `RAID/disk (iDRAC)`).
  Requires **PowerEdge 12th generation (R720-era) or newer** — that is when the
  `racadm storage` command set appeared (iDRAC7 fw 1.30.30+, iDRAC8/9); older
  iDRAC is reported as unsupported rather than failed. Otherwise falls back to
  physical-disk `HealthStatus` + SMART predicted-failure
  (`MSStorageDriver_FailurePredictStatus`). Skipped automatically on VMs.
- **Auto services** — automatic-start services that are not running
- **Memory** — physical RAM in use (WARN ≥ 85%, FAIL ≥ 95%)
- **Pagefile** — page file in use (WARN ≥ 80%, FAIL ≥ 95%)
- **System errors (24h)** — error events in the System log in the last 24 hours
- **Uptime** — time since last boot

`[E]` writes the summary plus supporting detail tables (disk, physical-disk
health, stopped services, recent errors, top memory, active sessions) to a
timestamped file at `C:\AdminReports\HealthReport_<COMPUTERNAME>_<timestamp>.txt`.

### Top Resource Users `[2]`

Samples live performance counters for a few seconds to show an accurate *current*
top-CPU list (averaged, normalized to total CPU) alongside top memory consumers.
Note: Windows keeps no per-process history, so this is a point-in-time view, not
a 24-hour trend. On non-English systems the counter path may differ; the command
falls back to cumulative CPU time if live sampling is unavailable.

> **Hardware RAID note:** the OS only sees the virtual disk presented by a RAID
> controller, so `Get-PhysicalDisk`/SMART can't see drives behind hardware RAID.
> On **Dell** servers (PowerEdge **12th generation / R720-era and newer**) this
> tool uses local `racadm` (iDRAC Tools) to read true array/drive health.
> `racadm` property names vary by iDRAC firmware, so the parser is best-effort
> and the report also captures the raw `racadm storage` output — verify the
> `RAID/disk (iDRAC)` verdict against your fleet and adjust the parsing in
> `Get-DellStorageHealth` if a field name differs. Older generations lack the
> `racadm storage` command set and are reported as unsupported. For non-Dell
> hardware, use the appropriate vendor CLI (`perccli`/`storcli`, `ssacli`, etc.).

## Files

| File                       | Purpose                                                        |
|----------------------------|---------------------------------------------------------------|
| `AdminProfile.ps1`         | The profile itself — banner, menu, and all task functions.     |
| `Deploy-AdminProfile.ps1`  | Deploys the profile to all users on local or remote servers.   |
| `Remove-AdminProfile.ps1`  | Rolls back the profile, restoring any backup that was made.    |

## Deployment

Run from an elevated (Administrator) PowerShell prompt.

```powershell
# Local server
.\Deploy-AdminProfile.ps1

# One or more remote servers (uses the \\SERVER\Admin$ share)
.\Deploy-AdminProfile.ps1 -ComputerName SRV01,SRV02,SRV03 -Force
```

The profile is written to the **AllUsersAllHosts** path:

- Windows PowerShell 5.x: `%SystemRoot%\System32\WindowsPowerShell\v1.0\profile.ps1`
- PowerShell 7+: `%ProgramFiles%\PowerShell\7\profile.ps1`

Existing profiles are backed up with a timestamped `.bak_` suffix before being
overwritten.

## Rollback

```powershell
.\Remove-AdminProfile.ps1 -ComputerName SRV01
```

Restores the most recent backup if one exists; otherwise removes the deployed
profile.

## Rebranding

The banner is configurable at the top of `AdminProfile.ps1`. Replace
`$BannerLines` / `$BannerSubtitle` and set `$BannerColor`. Generate new ASCII
art with the "Standard" figlet font at <https://patorjk.com>.

## Requirements

- Windows Server (or Windows client) with PowerShell 5.1+ or PowerShell 7+
- Administrator rights to deploy and to run the administrative tasks
- Optional: the `PSWindowsUpdate` module for the "Pending Windows Updates" option
  (`Install-Module PSWindowsUpdate`)
