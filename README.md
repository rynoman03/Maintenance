# Maintenance-

Scripts and notes used for Windows systems maintenance tasks. This repository is a practical, growing collection of PowerShell-style scripts for common administrator workflows such as Active Directory group management, TLS registry configuration, printer inventory, connectivity checks, scheduled reboots, and email notifications.

> [!CAUTION]
> Several scripts make machine-wide changes, such as editing `HKLM:` registry keys, creating Active Directory objects, or scheduling reboots. Review and test scripts in a lab before running them in production.

## Repository layout

Scripts are grouped into folders by function rather than left loose at the
repository root; there is still no packaged application or build step, just
standalone scripts organized by what they manage.

| File | Purpose |
| --- | --- |
| `ActiveDirectory/UserGroup.ps1` | Interactive Active Directory group creation script. It creates or finds an owner group, creates a main group, sets the main group's `ManagedBy` attribute, and can add users to the owner group. |
| `TLS/` | TLS protocol configuration scripts (SCHANNEL registry). See below. |
| `TLS/Disable TLS 1.0 and 1.1  Client & Server` | Disables TLS 1.0 and TLS 1.1 for both client and server roles by writing SCHANNEL registry keys. |
| `TLS/Enable TLS 1.2 on Client and Server` | Enables TLS 1.2 client and server registry settings. |
| `TLS/Enable TLS 1.3 on Client and Server` | Enables TLS 1.3 client and server registry settings and updates .NET strong crypto registry values where present. |
| `Printing/Get-PrintQueueInventory.ps1` | Builds an Excel-based printer inventory from one or more print servers using WMI and Excel COM automation. |
| `Networking/PingIt.ps1` | Reads a server list (`-Path`, default `.\servers.txt`) and checks whether each responds to `Test-Connection`, in parallel on PowerShell 7+. Prints a reachable/unreachable summary and optionally exports results via `-ReportPath`. |
| `Notifications/Sendmail.ps1` | Sends a maintenance notification email through an SMTP server. Intended for use with Windows Task Scheduler or other automation. |
| `Notifications/SystemRebootTask_and_Email.ps1` | Creates a scheduled task intended to send an email and reboot a system at a scheduled time. |
| `iDRAC/IdracManager.ps1` | Windows PowerShell iDRAC manager that uses Redfish over HTTPS for power state, health, firmware, thermal, user, and basic security-audit checks. |
| `iDRAC/IdracManager.cmd` | Windows command prompt launcher for `IdracManager.ps1`; prefers PowerShell 7 (`pwsh.exe`) and falls back to Windows PowerShell (`powershell.exe`). |
| `AdminHub/` | Interactive server-administration console and health-check module, packaged as its own PowerShell module. See `AdminHub/README.md`. |

## General structure

There is no compiled application, package manifest, or formal test suite. Each script should be reviewed as an independent maintenance tool with its own requirements and risks.

Common patterns across the repository include:

- Windows PowerShell commands and syntax.
- Windows registry edits through the `HKLM:` provider.
- Active Directory PowerShell cmdlets.
- WMI queries for printer and driver data.
- Windows Task Scheduler cmdlets.
- Environment-specific placeholders that must be changed before use.
- Redfish API calls to Dell iDRAC interfaces over HTTPS.

## Important things to know before running scripts

### Run from an appropriate Windows environment

These scripts are written for Windows administration. Many of them will not run correctly from Linux, macOS, or non-Windows PowerShell sessions because they depend on Windows-only providers, modules, COM objects, WMI classes, or system tools.

### Use administrative privileges where required

Scripts that write to `HKLM:` registry paths, create scheduled tasks, or perform server maintenance usually need to be run from an elevated PowerShell session.

### Replace placeholders first

Several scripts contain placeholder values that should be updated for your environment before execution:

- Active Directory paths such as `OU=Groups,DC=domain,DC=com`.
- Print server names such as `printservernamehere1`.
- SMTP server names, sender addresses, and recipient addresses.
- Domain user values such as `DOMAIN\user`.
- Script paths such as `C:\scripts\sendmail.ps1`.
- Dell iDRAC host names, IP addresses, and credentials.

### Test in a lab first

Before running a script against production servers, test with a disposable VM, test OU, test print server, or non-production maintenance window. This is especially important for scripts that:

- Disable or enable TLS protocols.
- Create or modify Active Directory groups.
- Reboot a machine.
- Query many remote servers.
- Send email notifications to real users.

### Quote filenames with spaces

The TLS scripts' filenames contain spaces (matching their descriptive
Windows-registry-change names). When running them directly, quote the path:

```powershell
& ".\TLS\Enable TLS 1.2 on Client and Server"
```

## Script notes

### `ActiveDirectory/UserGroup.ps1`

Use this script when you need to create a security group, associate it with an owner group, and optionally add users to that owner group.

Before use:

- Confirm the Active Directory PowerShell module is installed.
- Update the target OU path.
- Run with an account that has permission to create groups and modify group membership.
- Consider adding validation and better error output before broad production use.

### TLS scripts

The TLS scripts change Windows SCHANNEL and related registry settings. These changes can affect application compatibility and may require a restart.

Before use:

- Confirm the target Windows Server or Windows client version supports the TLS version being configured.
- Confirm application dependencies are compatible with the enabled or disabled protocols.
- Export or document the existing registry values before changing them.
- Test on non-production systems first.

### `Printing/Get-PrintQueueInventory.ps1`

This script uses Excel automation and WMI to create a printer inventory workbook.

Before use:

- Run from a Windows machine with Microsoft Excel installed.
- Use an account with access to query the target print servers.
- Replace the default print server list.
- Expect the script to open Excel visibly while it runs.


### `iDRAC/IdracManager.ps1` and `IdracManager.cmd`

`IdracManager.ps1` is a Windows-native Dell iDRAC manager inspired by menu-driven iDRAC maintenance tools. It uses the Redfish API over HTTPS and can run interactively or with action switches. `IdracManager.cmd` is a convenience launcher for administrators who prefer `cmd.exe`, shortcuts, or batch files. Both live in `iDRAC/` and locate each other relative to their own folder, so run them from there (or with a full path).

Prerequisites:

- Windows PowerShell 5.1 or PowerShell 7+.
- Network access from the workstation to the iDRAC HTTPS endpoint, usually TCP port 443.
- iDRAC credentials with permission to view inventory, health, and user information.
- Power-control permissions if you use the power-action menu.

Interactive examples:

```powershell
.\iDRAC\IdracManager.ps1
.\iDRAC\IdracManager.ps1 -HostName 192.168.1.100 -Username root
.\iDRAC\IdracManager.ps1 -HostName idrac01.example.com -GetHealth -GetPowerState
```

Command Prompt examples (from the `iDRAC/` folder):

```cmd
IdracManager.cmd
IdracManager.cmd -HostName 192.168.1.100 -Username root
IdracManager.cmd -HostName idrac01.example.com -SecurityAudit
```

Available read-only checks include:

- Power state and basic system identity.
- System, manager, and chassis health.
- Firmware inventory.
- Temperature and fan sensors.
- iDRAC local users.
- A basic security audit for enabled default/common accounts and account lockout settings.

Certificate notes:

- Many iDRAC interfaces use self-signed certificates. If you trust the target and need to connect anyway, add `-SkipCertificateCheck`.
- Do not use `-SkipCertificateCheck` for untrusted networks or unknown devices because it bypasses certificate validation.
- The script writes a timestamped log file in the repository directory by default. Use `-LogPath C:\Logs\idrac.log` to choose a different path.

Security notes:

- Prefer secure prompts by omitting `-Password`; the script will use `Get-Credential`.
- Avoid putting passwords in command history, scripts, shortcuts, or scheduled task arguments.
- Test against a non-production iDRAC before running checks broadly.
- Power actions are gated behind PowerShell confirmation prompts because they can interrupt running systems.

### `Networking/PingIt.ps1`

This is a simple connectivity helper. Create a server list file (default `servers.txt`, in the same directory as the script, or point `-Path` at another file), then add one server name per line — blank lines and lines starting with `#` are ignored.

Example `servers.txt`:

```text
server01
server02
server03
```

```powershell
# Default: reads .\servers.txt next to the script
.\Networking\PingIt.ps1

# Custom list, plus a CSV of results
.\Networking\PingIt.ps1 -Path C:\lists\dc-servers.txt -ReportPath C:\Reports\pingit.csv
```

Pings run in parallel on PowerShell 7+ and serially on Windows PowerShell 5.1. Output includes a reachable/unreachable summary line in addition to the per-server results.

### `Notifications/Sendmail.ps1` and `Notifications/SystemRebootTask_and_Email.ps1`

These scripts are intended to work together: one sends an email notification, and the other schedules a reboot workflow. `SystemRebootTask_and_Email.ps1` currently points at a hard-coded deployment path (`C:\scripts\sendmail.ps1`) for where `Sendmail.ps1` should be copied on the target machine — that's a target-machine path, not a path inside this repo, so update it to wherever you actually deploy the script.

Before use:

- Update SMTP settings and email addresses.
- Update the scheduled task user.
- Update the path to `sendmail.ps1`.
- Validate the scheduled task trigger syntax in a test environment.
- Confirm the reboot window with stakeholders before registering or running the task.

## Suggested learning path for newcomers

1. **PowerShell basics**
   - Variables, arrays, loops, conditionals, and pipelines.
   - `param()` blocks and script parameters.
   - `try` / `catch` error handling.
   - Running scripts with execution policy considerations.

2. **Windows administration with PowerShell**
   - Registry management with `New-Item`, `New-ItemProperty`, and `Set-ItemProperty`.
   - Active Directory automation with `Get-ADGroup`, `New-ADGroup`, `Set-ADGroup`, and `Add-ADGroupMember`.
   - Scheduled task automation with `New-ScheduledTaskAction`, `New-ScheduledTaskTrigger`, and `Register-ScheduledTask`.

3. **Remote inventory and reporting**
   - WMI and CIM concepts.
   - Printer-related classes such as `Win32_Printer`, `Win32_TcpIpPrinterPort`, and `Win32_PrinterDriver`.
   - Exporting results to CSV or Excel.

4. **Script hardening**
   - Add `.ps1` extensions for consistency.
   - Convert hard-coded values into parameters.
   - Add input validation.
   - Add `-WhatIf` and `-Confirm` support for risky operations.
   - Add logging and clearer error messages.
   - Document required permissions for each script.

## Future improvement ideas

- Add per-script usage examples.
- Add a `docs/` folder for operational runbooks.
- Add a `servers.txt.example` file for `Networking/PingIt.ps1`.
- Add parameterized versions of scripts that currently rely on hard-coded values.
- Add PowerShell Script Analyzer checks for the root-level scripts (AdminHub already has its own, see `AdminHub/README.md`).
- Add safer dry-run behavior for scripts that modify registry, Active Directory, or scheduled tasks.
