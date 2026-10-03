# WSUS Manager

WSUS Manager runs on your admin workstation and connects to the WSUS server
you choose. From there it can:

- **List update groups** (WSUS computer target groups) and the computers in each.
- **Show update info**: each computer's status (needed, failed, pending reboot,
  installed), the updates a group still needs, or the updates one computer needs.
- **Report on reboots**: which computers need a reboot. It combines what WSUS
  knows with a live check of each client's reboot-pending flags.
- **Report system uptime**: last boot time and uptime for each computer, and
  flags anything up longer than a threshold you set.
- **Force a reboot**: either every target, or only the ones that have a reboot pending.
- **Force updates**: tells each client to download and install its updates now,
  and can reboot afterwards if an update needs it.
- **Force a check-in**: tells clients to detect against WSUS and report their
  status now.
- **Set registry settings for updates**: applies a Windows Update policy
  baseline (`WsusClientBaseline.json`).
- **Check registry compliance**: compares each client's registry against that
  same baseline.

You can use it as an interactive menu, or run it headless with `-Action` for
scheduled jobs. Any result can be exported to **CSV, HTML or JSON**.

> [!CAUTION]
> Forced reboots, forced installs and registry changes affect real machines.
> Every one of them asks for confirmation and supports `-WhatIf`. Try them on a
> test group first.

## Files

| File | Purpose |
| --- | --- |
| `WsusManager.exe` | **Portable single-file app** (built from the files below). Copy it anywhere and run it. Nothing to install. |
| `WsusManager.ps1` | Launcher / CLI (menu + `-Action` mode). It is the same code the exe is built from. |
| `WsusManager.psm1` / `.psd1` | The PowerShell module with every function. |
| `WsusClientBaseline.json` | Windows Update registry baseline, used both to apply settings and to check compliance. Edit it to fit your environment. |
| `WsusManager.cmd` | Double-click launcher. It uses `WsusManager.exe` if it's next to it, otherwise Windows PowerShell. |
| `Build-WsusManagerExe.ps1` | Builds `dist\WsusManager.exe` with PS2EXE. |
| `Tests/` | Pester tests (CI: `.github/workflows/wsus-ci.yml`). |

## Getting the exe

- **Easiest:** open the latest **WSUS Manager CI** run on GitHub (Actions tab)
  and download the **WsusManager** artifact. It contains `WsusManager.exe`,
  `WsusClientBaseline.json` and this README.
- **Build it yourself** on any Windows machine:

  ```powershell
  cd WSUS
  .\Build-WsusManagerExe.ps1        # installs PS2EXE for your user if needed
  # -> dist\WsusManager.exe + dist\WsusClientBaseline.json
  ```

The exe runs on Windows PowerShell 5.1, which ships with every supported
version of Windows. Keep `WsusClientBaseline.json` next to the exe to use your
own edited baseline. If the file isn't there, the exe falls back to the
default copy built into it.

> [!NOTE]
> Exes built with PS2EXE are sometimes flagged by antivirus heuristics.
> Signing the exe with your organization's code-signing certificate
> (`Set-AuthenticodeSignature`) avoids most of that.

## How it connects (nothing to install locally)

You run the app **locally** and tell it **which WSUS server** to use: either
with `-WsusServer` or at the startup prompt. The prompt remembers the last
server you used, in `%APPDATA%\WsusManager\settings.json`.

| Part | How it is reached | What you need |
| --- | --- | --- |
| WSUS queries (groups, update status, needed updates, WSUS reboot counts) | **Local mode:** if the WSUS console / RSAT "Windows Server Update Services Tools" is installed on your machine, it uses that API directly. **Remote mode:** otherwise the same query runs *on the WSUS server* over WinRM. | WSUS Administrators rights. Remote mode also needs WinRM to the WSUS server. |
| Client actions and live checks (uptime, reboot pending, check-in, install, reboot, registry) | PowerShell remoting (WinRM) to each target computer. `localhost` runs in-process. | Local admin on the targets, and WinRM enabled (the default on Windows Server). |

Use `-ConnectionMode Local|Remote` to force a mode. Use `-Credential`
(or `-PromptForCredential`) to run as a different account.

## Interactive use

```powershell
WsusManager.exe                           # asks which WSUS server, then shows the menu
WsusManager.exe -WsusServer wsus01        # connect straight away
WsusManager.exe -WsusServer wsus01.contoso.com -Port 8531 -UseSsl
```

```
  ================= WSUS Manager =================
  WSUS: wsus01:8530 (Remote mode)
  ------------------ WSUS server -----------------
   1  Connect to WSUS server / server info
   2  List update groups
   3  Update status per computer (group)
   4  Needed updates for a group
   5  Needed updates for one computer
  -------------------- Reports -------------------
   6  Reboot-needed report (with uptime)
   7  System uptime report
   8  Live client status
  -------------------- Actions -------------------
   9  Force check-in (detect + report now)
  10  Force update install
  11  Update install results
  12  Force reboot
  -------------- Registry settings ---------------
  13  Show registry baseline
  14  Apply registry baseline
  15  Registry compliance report
  ------------------------------------------------
   E  Export last result    Q  Quit
```

Options that act on computers ask for a target: a **WSUS group**, a list of
**computer names**, or a **file** with one name per line.

## Headless use (`-Action`)

Pick the targets with `-GroupName`, `-ComputerName` or `-ComputerListPath`.
Add `-ReportPath report.html|.csv|.json` to save the result.

```powershell
# Update info
WsusManager.exe -WsusServer wsus01 -Action Groups
WsusManager.exe -WsusServer wsus01 -Action UpdateStatus  -GroupName Servers -ReportPath C:\Reports\status.html
WsusManager.exe -WsusServer wsus01 -Action NeededUpdates -GroupName Servers -UpdateApproval Approved
WsusManager.exe -WsusServer wsus01 -Action NeededUpdates -ComputerName web01

# Reboot-needed and uptime reports
WsusManager.exe -WsusServer wsus01 -Action RebootReport -GroupName Servers -ReportPath C:\Reports\reboot.html
WsusManager.exe -Action UptimeReport -ComputerListPath .\servers.txt -UptimeThresholdDays 30

# Force check-in / updates / reboot
WsusManager.exe -WsusServer wsus01 -Action CheckIn        -GroupName Servers -ResetAuthorization
WsusManager.exe -WsusServer wsus01 -Action InstallUpdates -GroupName Servers -RebootIfRequired
WsusManager.exe -WsusServer wsus01 -Action InstallResult  -GroupName Servers
WsusManager.exe -WsusServer wsus01 -Action Reboot         -GroupName Servers -OnlyIfRebootPending -DelaySeconds 300

# Registry settings and compliance
WsusManager.exe -WsusServer wsus01 -Action ComplianceSummary -GroupName Workstations
WsusManager.exe -WsusServer wsus01 -Action ComplianceReport  -GroupName Workstations -ReportPath C:\Reports\compliance.html
WsusManager.exe -WsusServer wsus01 -Action SetRegistry       -GroupName Workstations -WhatIf
WsusManager.exe -WsusServer wsus01 -Action SetRegistry       -GroupName Workstations -RestartUpdateService
```

Actions that change computers prompt for confirmation. For unattended
(scheduled) runs, add `-Confirm:$false`.

**Exit codes:**

- `0`: OK.
- `1`: error.
- `2`: findings: non-compliant computers, reboots needed, uptime over the
  threshold, or a failed client action.

Exit code 2 lets a scheduled task or a monitoring system alert on the result.

The same features are available as module functions. For example:
`Import-Module .\WsusManager.psd1; Connect-WsusManagerServer wsus01; Get-WsusManagerRebootReport -GroupName Servers`.

## The registry baseline

`WsusClientBaseline.json` lists the values under
`HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` (and `\AU`) that
clients should have. The **same file** is used both to apply settings and to
check compliance, so what you check is always what you configure.

```json
{
  "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU",
  "Name": "AUOptions",
  "Type": "DWord",
  "Value": 4,
  "AllowedValues": [3, 4],
  "Description": "Compliant if 3 or 4; 4 is written."
}
```

- `Type`: `String`, `ExpandString`, `DWord`, `QWord` or `MultiString`.
- `Ensure`: `Present` (the default) or `Absent`. Use `Absent` for a value that must *not* exist.
- `AllowedValues` (optional): compliance accepts any of these. Apply writes `Value`.
- Tokens:
  - `{WsusServerUrl}`: the WSUS server you connected to, e.g. `http://wsus01:8530`. Override it with `-WsusServerUrl`.
  - `{TargetGroup}`: the WSUS group you targeted. Override it with `-TargetGroup`.

Each check returns one row per computer per setting. The status is one of:

- `Compliant`
- `NonCompliant`: wrong value or wrong type.
- `Missing`
- `Error`: the computer was unreachable.

`ComplianceSummary` rolls the rows up to one line per computer, with a percentage.

How applying works:

1. The tool checks compliance first and **only writes settings that are not
   already compliant**.
2. Before writing, it backs up the previous values to
   `%ProgramData%\WsusManager\Logs\RegistryBackup-<timestamp>.csv`.
3. With `-RestartUpdateService`, it then restarts `wuauserv` and forces a check-in.

> [!IMPORTANT]
> Values under `SOFTWARE\Policies` are normally owned by Group Policy. If a
> GPO sets the same value, the GPO wins at the next policy refresh. For
> domain-joined machines, fix the GPO and use this tool's compliance report
> to verify the result. Direct registry apply is mainly for workgroup or
> non-GPO machines, and for quick remediation.

## How the client actions work

- **Reboot needed / uptime.** The tool reads each client's reboot-pending flags:
  - Windows Update `RebootRequired`
  - CBS `RebootPending`
  - `PendingFileRenameOperations`
  - a pending computer rename
  - the ConfigMgr client, if present
  - the WUA `SystemInfo.RebootRequired` flag

  It also reads `Win32_OperatingSystem.LastBootUpTime` to work out uptime. The
  reboot report also includes WSUS's "installed, pending reboot" count for
  each computer.
- **Check-in.** Starts `wuauserv` if needed, then calls `AutoUpdate.DetectNow()`,
  `UsoClient StartScan` and `wuauclt /reportnow`. Optional extras:
  - `-ResetAuthorization` also runs `wuauclt /resetauthorization`.
  - `-WaitForScan` runs a full synchronous scan and returns the applicable count.
- **Install.** Windows Update won't download or install updates from a remote
  session. So the tool registers a one-off scheduled task named
  `WsusManager-InstallUpdates` that runs as SYSTEM, and starts it. That task:
  1. searches for applicable updates and accepts their EULAs,
  2. downloads and installs them,
  3. reboots after 60 seconds, if `-RebootIfRequired` was used and an update
     needs it.

  Progress goes to `C:\ProgramData\WsusManager\InstallUpdates.log` on the
  client. Use **Install results** / `-Action InstallResult` to collect the outcome.
- **Reboot.** Runs `shutdown /r /f` with your delay and message, logged as a
  planned restart (reason code `p:2:17`).

Every action is logged to `%ProgramData%\WsusManager\Logs\WsusManager-<date>.log`.
Use `-LogDirectory` to change where logs go.

## Requirements

- Windows PowerShell 5.1 or later (the exe uses the 5.1 that ships with Windows).
- An account with:
  - WSUS Administrators rights on the WSUS server,
  - local admin on the target computers.
- WinRM (PowerShell remoting) enabled on the targets. In Remote mode it must
  also be enabled on the WSUS server.

## Testing

```powershell
cd WSUS
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\ScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\Tests
```

The tests need no WSUS server and no remote computers. They cover:

- the baseline logic: loading, tokens, value comparison and the compliance
  roll-up,
- the reboot/uptime merge,
- target resolution,
- report export,
- the single-file build that the exe is made from.
