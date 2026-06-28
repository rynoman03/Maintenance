# Admin Hub

An administrative PowerShell profile for Windows Servers. When deployed to the
**AllUsersAllHosts** profile location, every user who opens PowerShell on the
server is greeted with a banner and an interactive menu of common
administrative tasks — with the option to drop to a normal shell at any time.

```
     _       _           _       _   _       _
    / \   __| |_ __ ___ (_)_ __ | | | |_   _| |__
   / _ \ / _` | '_ ` _ \| | '_ \| |_| | | | | '_ \
  / ___ \ (_| | | | | | | | | | |  _  | |_| | |_) |
 /_/   \_\__,_|_| |_| |_|_|_| |_|_| |_|\__,_|_.__/
Server Administration Console
```

## Screenshots

The menu shown at startup:

```text
============================================================
  SERVER ADMIN MENU  -  SRV-DB01  [Standard user]
============================================================
  System & Diagnostics
  [1]  Disk Space
  [2]  Top Resource Users (live)
  [3]  Restart / Kill a Service
  [4]  Windows Updates (pending + history)
  [5]  Full System Health Check
  [M]  Top 10 Memory Usage
  [S]  Top 10 Swap/Page File
  [A]  Active User Sessions
  [L]  Tail a Log File

  Networking
  [N]  Adapters, teaming, DNS, gateway
  [P]  Listening Ports / Connections

  Maintenance
  [C]  Disk Cleanup (C: drive)
  [E]  Export Health Report

  [R]  Relaunch as Administrator
  [0]  Exit to Shell
============================================================
  Note: tasks like [3] and [C] need admin - press [R] to elevate.
  Tip: after a task, press [X] then Enter to exit  -  type Show-AdminMenu to reopen.

  Select an option
```

> The `[R]` option and the admin note appear only in a non-elevated session;
> when running as Administrator the header shows `[Administrator]` and both are
> omitted.

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
  [WARN] System errors (24h)   4 error/critical event(s)
  [OK  ] Network adapters      2 up; errors: 0, discards: 0 (since boot)
  [FAIL] Default gateway       unreachable: 10.20.0.1
  [WARN] NIC teaming           Team1 1/2
  [OK  ] DNS resolution        resolved corp.example.com
  [WARN] Network location      NlaSvc running; profile: Public; Public profile may block inbound ping
  [OK  ] Hardware (temp/PSU)   all temperature/power sensors Ok [Dell racadm]
  [WARN] CPU/memory faults     3 WHEA event(s) (0 uncorrected)
  [OK  ] Time sync             offset +0.42s from corp.example.com
  [WARN] Certificate expiry    1 expiring; soonest: CN=web.corp (12d)
  [OK  ] Scheduled tasks       no failed non-Microsoft tasks
  [OK  ] Security posture      Defender/firewall/SMBv1/UAC all OK
  [OK  ] Listening ports       28 TCP, 14 UDP listening; 53 established
  [OK  ] Uptime                21d 7h since last boot

  Overall: FAIL
  Report saved to: C:\AdminReports\HealthReport_SRV-DB01_20260626_143052.txt
  Size: 9.7 KB
```

> Output is color-coded in the console (green/yellow/red); GitHub renders these
> samples in monochrome. To add a real color screenshot, capture your PowerShell
> window and drop a PNG in `AdminHub/images/`, then reference it here.

## Sample output by option

Representative output for each menu option (illustrative `SRV-DB01` data).

### System & Diagnostics

**`[1]` Disk Space** — per-drive usage, then an optional scan for the largest files:

```text
============================================================
  Disk Space
============================================================

Name Used(GB) Free(GB) Total(GB)
---- -------- -------- ---------
C        78.4    42.11    120.51
D       210.9   289.10    500.00
E       921.0    78.70    999.70

  Scan drives for the 5 largest files? Can be slow on large volumes [Y/N]: Y

  Top 5 largest files on C: (scanning, may take a while on large drives)...

Size(MB) FullName
-------- --------
 8192.00 C:\pagefile.sys
 4096.00 C:\Windows\MEMORY.DMP
 2048.55 C:\Program Files\Microsoft SQL Server\MSSQL\DATA\tempdb.mdf
  912.30 C:\inetpub\logs\LogFiles\W3SVC1\u_ex260626.log
  640.10 C:\Windows\Logs\CBS\CBS.log
```

**`[2]` Top Resource Users** — live-sampled CPU plus working-set memory:

```text
============================================================
  Top Resource Users (CPU sampled over 3s)
============================================================
  Sampling CPU...

============================================================
  Top 10 by CPU (% of total CPU)
============================================================

Name        CPU%
----        ----
sqlservr    34.2
w3wp        12.7
MsMpEng      6.1

============================================================
  Top 10 by Memory (working set)
============================================================

Name       Id Mem(MB) PrivateMem(MB)
----       -- ------- --------------
sqlservr 1840 8421.55        8102.33
w3wp     5210 1422.10        1290.04
```

**`[3]` Restart / Kill a Service** — shows PID/owning process and blast radius, then restart or force-kill:

```text
  Enter service name or display name: Spooler

============================================================
  Service: Print Spooler
============================================================
  Name      : Spooler
  Status    : Running
  StartType : Auto
  PID       : 4148 (svchost)
  SHARED PID: also hosts 1 other service(s): Fax
  Killing this process stops ALL of them.

  [R] Restart    [K] Kill process (force)    [C] Cancel
  Choose: K
  Force-kill PID 4148 (svchost) and 1 co-hosted service(s)? Abrupt - unsaved state is lost. [Y/N]: Y
  Killed PID 4148.
  Start the killed service(s) again now? [Y/N]: Y
  Started Spooler.
  Started Fax.
  Now: Running  (PID 9012)
```

A kill that would crash the box is refused:

```text
  [R] Restart    [K] Kill process (force)    [C] Cancel
  Choose: K
  Refusing to kill PID 1612: hosts kernel-critical service(s) [RpcSs, RpcEptMapper] - killing it would crash the OS.
  Use [R] Restart instead.
```

**`[4]` Windows Updates (pending + history)** — last-applied date, pending list
(needs admin), reboot status, and an optional by-date installed history. The
last-applied date, reboot status, and history work without elevation:

```text
============================================================
  Windows Updates
============================================================
  Last update installed: 2026-06-20  (7 days ago)

KB        Title                                 Size   MsrcSeverity
--        -----                                 ----   ------------
KB5040442 2026-06 Cumulative Update for Server  712 MB Critical

  REBOOT PENDING - Windows Update

  View installed updates by date? [Y/N]: Y

Date       Result    Title
----       ------    -----
2026-06-20 Succeeded 2026-06 Cumulative Update for Windows Server (KB5040442)
2026-06-12 Succeeded Security Intelligence Update ... (KB2267602)
2026-05-14 Succeeded 2026-05 Cumulative Update for Windows Server (KB5037782)
```

> Run without admin and the pending-search line is replaced with
> "Pending-update check needs admin - press [R] to elevate"; everything else
> still shows.

**`[M]` Top 10 Memory Usage**:

```text
============================================================
  Top 10 Processes by Memory Usage
============================================================

Name       Id Mem(MB) PrivateMem(MB) Handles
----       -- ------- -------------- -------
sqlservr 1840 8421.55        8102.33    1204
w3wp     5210 1422.10        1290.04     880
MsMpEng  2304  612.77         540.12     742
```

**`[S]` Top 10 Swap / Page File**:

```text
============================================================
  Top 10 Processes by Page File (Swap) Usage
============================================================
  Pagefile: C:\pagefile.sys  Used: 13456 MB / 16384 MB  (82%)

Name       Id PagedMem(MB) VirtualMem(MB) NonPagedMem(MB)
----       -- ------------ -------------- ---------------
sqlservr 1840      2104.22       18233.10           12.44
w3wp     5210       640.18        4221.55            8.10
```

**`[A]` Active User Sessions**:

```text
============================================================
  Active User Sessions
============================================================

SessionName Username      ID State
----------- --------      -- -----
services                  0  Disc
console     Administrator 1  Active
rdp-tcp#2   r.cashier     3  Active
```

**`[L]` Tail a Log File** — quick-pick of common logs (or paste a path):

```text
============================================================
  Tail a Log File
============================================================
  Quick pick a common log, or enter a path:
    [1] CBS (Windows servicing)
        C:\Windows\Logs\CBS\CBS.log
    [2] IIS logs (newest)
        C:\inetpub\logs\LogFiles
    [3] System32 LogFiles
        C:\Windows\System32\LogFiles
    [4] AdminHub health reports
        C:\AdminReports
    [P] Enter a custom path
  Select a number, P, or paste a path: 2

  Directory given - tailing newest file: u_ex260627.log
  How many lines? [default 20]: 10
  Follow live, like tail -f? [Y/N]: N

  --- C:\inetpub\logs\LogFiles\W3SVC1\u_ex260627.log  (last 10 lines) ---
  2026-06-27 14:31:02 GET /health 200 12
  2026-06-27 14:31:09 POST /api/login 200 41
```

### Networking

**`[N]` Network** — adapters, gateway ping, NIC teaming, DNS, and network location:

```text
============================================================
  Network Adapters
============================================================

Name  LinkSpeed RxDiscarded RxErrors TxDiscarded TxErrors
----  --------- ----------- -------- ----------- --------
Team1     2 Gbps           0        0           0        0

  No discards or errors on any connected adapter.

============================================================
  Default Gateway
============================================================
  [OK]   10.20.0.1 via Team1 - reachable

============================================================
  NIC Teaming
============================================================

Team  Mode LB      Status Members Active FailedMembers
----  ---- --      ------ ------- ------ -------------
Team1 Lacp Dynamic Up           2      2

  All teams healthy.

============================================================
  DNS
============================================================
  Servers: 10.20.0.10, 10.20.0.11
  Resolved corp.example.com -> 10.20.0.10, 10.20.0.11

============================================================
  Network Location (NLA)
============================================================
  [OK] NlaSvc running; profile: DomainAuthenticated
```

**`[P]` Listening Ports / Connections**:

```text
============================================================
  Listening Ports
============================================================

Proto LocalAddress Port ProcessId Process
----- ------------ ---- --------- -------
TCP   0.0.0.0       135      1744 svchost
TCP   0.0.0.0       445         4 System
TCP   0.0.0.0       3389     2332 svchost
TCP   0.0.0.0      1433      1840 sqlservr
TCP   0.0.0.0        80      4596 w3wp
UDP   0.0.0.0       123      1800 svchost

  5 TCP + 1 UDP listening.

============================================================
  Active TCP Connections
============================================================
  Established  37
  TimeWait     12
  Listen        9

  Established (up to 15):

Local           Remote           Process
-----           ------           -------
10.20.0.40:1433 10.20.0.55:51022 sqlservr
10.20.0.40:80   10.20.0.60:49788 w3wp
```

### Maintenance

**`[C]` Disk Cleanup** — previews recoverable space, then cleans on confirmation:

```text
============================================================
  Disk Cleanup - C:
============================================================

Location                      Files Size(MB)
--------                      ----- --------
Windows Temp                    412   318.44
User Temp                      1203   221.07
CBS Logs                         58   612.90
SoftwareDistribution\Download   340  1844.21

  Total recoverable: 2996.62 MB

  Proceed with cleanup? [Y/N]: Y
  Cleaned: Windows Temp
  Cleaned: User Temp
  Cleaned: CBS Logs
  Cleaned: SoftwareDistribution\Download

  Done. Freed approximately 2996.62 MB on C:.
  C: - Used: 75.4 GB  Free: 45.1 GB  Total: 120.5 GB
```

**`[E]` Export Health Report** — prints the health summary shown above and writes the
full report to `C:\AdminReports\HealthReport_<COMPUTERNAME>_<timestamp>.txt`.

## Menu options

On screen the menu is grouped into **System & Diagnostics**, **Networking**
(`[N]` and `[P]`), and **Maintenance** sections. The keys are unchanged:

| Key | Option                      | Type        |
|-----|-----------------------------|-------------|
| 1   | Disk Space                  | Read        |
| 2   | Top Resource Users (live)   | Read        |
| 3   | Restart / Kill a Service    | Action      |
| 4   | Windows Updates (pending + history) | Action |
| 5   | Full System Health Check    | Read        |
| M   | Top 10 Memory Usage         | Read        |
| S   | Top 10 Swap / Page File     | Read        |
| A   | Active User Sessions        | Read        |
| L   | Tail a Log File             | Read        |
| N   | Network: adapters, teaming, DNS, gateway | Read |
| P   | Listening Ports / Connections | Read       |
| C   | Disk Cleanup (C: drive)     | Destructive |
| E   | Export Health Report        | Action      |
| R   | Relaunch as Administrator   | Elevation   |
| 0   | Exit to Shell               | —           |

The menu loads in both standard and elevated sessions, so you can just open
PowerShell normally. The header shows `[Administrator]` or `[Standard user]`,
and the `[R]` option (shown only when not elevated) relaunches PowerShell as
Administrator via UAC for tasks that need it (e.g. restart service, disk
cleanup).

After any task runs, you get a `[Enter] Return to menu / [X] Exit to shell`
prompt so output stays on screen — press `X` then Enter to drop to the shell.
Exiting leaves all task functions loaded in the session; type `Show-AdminMenu`
at any time to reopen the menu. The menu also shows this tip on screen each time
it is drawn.

### Disk space `[1]`

Shows used/free/total per filesystem drive, then offers to list the **top 5
largest files on each fixed drive** (with full path) to help track down what's
filling a volume. Because finding the largest files means walking the whole
drive, it first asks `Y/N` (it can be slow on large volumes); answer `Y` to
scan. It uses a streaming top-N scan (only the current 5 are held in memory) and
skips paths it can't read. This file scan runs only from the `[1]` menu option;
the same disk-space summary inside the health check `[5]` stays fast and never
scans files.

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
- **System errors (24h)** — Error + Critical events in the System log in the
  last 24 hours (read via `Get-WinEvent`, so it works in both Windows PowerShell
  5.1 and PowerShell 7)
- **Network adapters** — for each connected (Up) adapter, the cumulative packet
  discard/error counters. WARN if any adapter shows packet **errors**; discard
  counts are reported for context (counters are totals since boot, so a few
  discards are usually benign). Requires the NetAdapter module (Server 2012+).
- **Default gateway** — pings (ICMP) the default gateway of each connected
  adapter; FAIL if any gateway does not respond.
- **NIC teaming** — for each LBFO team, the teaming mode (incl. `Lacp`) and how
  many member adapters are active. WARN if a team is not `Up` or is running on
  fewer adapters than configured (e.g. only one link passing traffic, or a
  failed member). Reported only where NIC teams exist.
- **DNS resolution** — on domain-joined machines, resolves the AD domain name to
  confirm DNS is answering; FAIL if it can't. Configured DNS servers are always
  listed. Skipped (not flagged) when not domain-joined.
- **Network location** — checks Network Location Awareness (`NlaSvc`) and the
  Network List Service (`netprofm`), plus the resulting connection-profile
  category. FAIL if `NlaSvc` is stopped; WARN if a profile is `Public`. This
  matters because if NLA misclassifies the network as Public, the Public Windows
  Firewall profile applies and **blocks inbound ICMP** — so remote pings and
  monitoring (e.g. Nagios) report the host as down even though it's up.
- **Hardware (temp/PSU)** — physical machines only (skipped on VMs): temperature
  and power-supply sensor health. On Dell servers this parses
  `racadm getsensorinfo` (best-effort; raw output is captured in the report);
  otherwise it falls back to ACPI thermal zones where available.
- **CPU/memory faults** — WHEA hardware-error events in the System log (machine
  checks, ECC memory errors) plus any processor reporting a non-OK status.
  Corrected errors → WARN, uncorrected → FAIL. Works on physical and virtual
  machines (VMs simply have no WHEA events).
- **Time sync** — domain-joined machines only: measures clock offset from the
  domain via `w32tm`. WARN at ≥ 2s drift, FAIL at ≥ 30s (well before Kerberos'
  5-minute skew limit).
- **Certificate expiry** — server-auth certificates (and no-EKU certs) in
  `LocalMachine\My`; WARN within 30 days, FAIL expired or within 7 days. The
  soonest expiry drives the verdict; the report lists each cert with days-left.
- **Scheduled tasks** — non-Microsoft scheduled tasks whose last run failed
  (benign `SCHED_S_*` status codes excluded); WARN with the failing task names.
- **Security posture** — Defender real-time protection + signature age (passive
  /EDR mode is respected), Windows Firewall (FAIL only if all profiles are off),
  SMBv1 enabled, BitLocker on the system drive (physical), and UAC. FAIL on the
  serious items, WARN on the softer ones.
- **Listening ports** — informational count of TCP/UDP listeners and established
  TCP connections (full per-port detail with owning process is under `[P]`).
- **Uptime** — time since last boot

In addition to the summary verdict, `[5]` prints the **most recent System-log
errors** (up to 20 Critical/Error events from the last 24 hours: time, level,
source, event ID, and first line of the message) so you can see the actual
events on screen, not just the count.

`[5]` also shows the network panel (adapters + default gateway ping + NIC
teaming + DNS + network location, also on its own via `[N]`), hardware
temperature/power, CPU/memory faults, and domain time sync. Checks that don't
apply to the machine (no teams, not domain-joined, a VM) report a short
"skipped"/"not available" note instead of failing.

`[E]` writes the summary plus supporting detail tables (disk, physical-disk
health, network adapters, default gateway, NIC teaming, DNS, network location,
listening ports, TCP connections by state, hardware sensors, CPU/memory faults,
domain time sync, stopped services, recent errors, top memory, active sessions)
to a timestamped file at `C:\AdminReports\HealthReport_<COMPUTERNAME>_<timestamp>.txt`.

### Listening ports & connections `[P]`

Lists every TCP/UDP **listening** endpoint with its owning process (so you can
see what the server exposes and which service owns each port), followed by a
breakdown of TCP connections by state (Established, TimeWait, etc.) and the
current established connections (local/remote address + process, up to 15).
Uses `Get-NetTCPConnection` / `Get-NetUDPEndpoint`.

### Tail a log file `[L]`

Like `tail` for Windows. Starts with a **quick-pick** of common server logs that
actually exist on the box — CBS servicing log, DISM, IIS logs, `System32\LogFiles`,
Windows setup (Panther), and the AdminHub health reports — or pick `[P]` / just
paste any path. The target can be a file, a directory (it tails the newest file
in it), or a wildcard (newest match). Choose how many lines to show (default 20)
and optionally **follow live** (`tail -f` via `Get-Content -Wait`). Following
blocks until `Ctrl+C`, which returns you to the shell (type `Show-AdminMenu` to
reopen the menu); non-follow mode prints the last N lines and returns to the menu.

### Restart / kill a service `[3]`

Resolves a service by exact name or display name and shows its status, start
type, **PID and owning process**, running dependents, and — when it runs in a
shared `svchost` — the other services hosted in the same process. Then offers:

- **`[R]` Restart** — normal `Restart-Service -Force` (warns first about running
  dependents that `-Force` will also bounce).
- **`[K]` Kill process (force)** — `Stop-Process -Force` for a service stuck in
  *Stopping*, behind a `Y/N` confirm, then optionally restarts the affected
  service(s).

The kill path is guarded so it can't crash the box: it **refuses** to kill a
process hosting a kernel-critical service (e.g. `RpcSs`, `DcomLaunch`, and the
other services sharing its `svchost`), double-checks the kernel's
`IsProcessCritical` flag, and re-validates that the PID still belongs to the
service immediately before killing (guarding against PID reuse). Restart/kill
require admin; the read-only details display without elevation.

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
| `AdminHub.psm1`            | The module — banner, menu, and all task/health functions.      |
| `AdminHub.psd1`            | Module manifest (version, exported commands, `adminhub` alias). |
| `AdminProfile.ps1`         | Thin profile shim — imports the module and shows the menu.      |
| `Deploy-AdminProfile.ps1`  | Installs the module (PSModulePath) + profile shim, local/remote.|
| `Remove-AdminProfile.ps1`  | Removes the module + profile, restoring any backup that was made.|
| `Install-UserProfile.ps1`  | Per-user install of the module + shim (no admin).              |

AdminHub is a **PowerShell module**. Because `Deploy-AdminProfile.ps1` installs
it under `PSModulePath`, its commands **autoload in any session — including
`Enter-PSSession`**: just type `adminhub`, `Show-AdminMenu`, or
`Invoke-SystemHealthCheck` on a remote server and the module loads on demand
(no profile required in remoting). The profile shim only adds the
auto-show-the-menu-on-console behavior on top.

To open the menu on a remote server in **one step** from your own console, use
`Enter-AdminSession <server>` (it runs the menu in a remote session via
`Invoke-Command`; add `-Credential` for cross-domain). The target must have the
module deployed and WinRM/PSRemoting enabled.

## Monitoring / non-interactive use

Dot-sourced as a profile, AdminHub shows the menu **only in an interactive
console** — remoting, `Invoke-Command`, `-NonInteractive`, piped-stdin, and
scheduled-task sessions load it silently without launching the menu, so it's
safe as an AllUsers profile on automated servers.

Run as a script, it doubles as a health probe for Nagios/Zabbix/Prometheus:

```powershell
powershell -NoProfile -File AdminProfile.ps1 -RunCheck            # text summary + exit code
powershell -NoProfile -File AdminProfile.ps1 -RunCheck -AsJson    # one JSON object
powershell -NoProfile -File AdminProfile.ps1 -RunCheck -Quiet     # exit code only
```

Exit codes follow the Nagios convention: **0 = OK, 1 = WARN, 2 = FAIL
(CRITICAL), 3 = UNKNOWN** (an `ERROR`'d check or an empty/failed summary maps to
UNKNOWN, so a dead check engine never looks healthy). `-AsJson` emits:

```json
{"host":"SRV-DB01","timestamp":"2026-06-27T22:10:05.1234567Z","overall":"FAIL",
 "checks":[{"Name":"Disk space","Status":"FAIL","Detail":"highest used: E: 92%","Value":92}, ...]}
```

`Value` carries a numeric where one makes sense (disk %, memory %, pagefile %,
offsets, counts) so checks can be graphed as trends, not just pass/fail.

## Personal install (no admin)

To load the menu for **just your own account** on a machine — handy on a
workstation — install it to your per-user profile. No administrator rights
required:

```powershell
.\Install-UserProfile.ps1                 # Windows PowerShell 5.x
.\Install-UserProfile.ps1 -AllEditions    # also PowerShell 7
```

Re-run it any time to refresh after changes. It copies `AdminProfile.ps1` to
`Documents\WindowsPowerShell\profile.ps1` (and `Documents\PowerShell\profile.ps1`
with `-AllEditions`), backing up a pre-existing non-AdminHub profile first. To
uninstall, delete that `profile.ps1`. For all-users / server installs, use
**Deployment** below instead.

## Deployment

Run from an elevated (Administrator) PowerShell prompt.

> **Execution policy:** these scripts are not digitally signed. If PowerShell
> blocks them with *"running scripts is disabled on this system"*, the execution
> policy needs to be relaxed once (per machine) from an elevated prompt:
>
> ```powershell
> Set-ExecutionPolicy RemoteSigned
> ```
>
> `RemoteSigned` lets locally-created scripts run while still requiring
> downloaded scripts to be signed. This only needs to be done once if it has not
> been enabled before. To check the current setting, run `Get-ExecutionPolicy`.

```powershell
# Local server
.\Deploy-AdminProfile.ps1

# One or more remote servers (uses the \\SERVER\Admin$ and \\SERVER\C$ shares)
.\Deploy-AdminProfile.ps1 -ComputerName SRV01,SRV02,SRV03 -Force
```

Deploy installs two things per edition: the **module** under `PSModulePath` (so
commands autoload everywhere, incl. `Enter-PSSession`) and the **profile shim**
at the AllUsersAllHosts path (so a console session auto-shows the menu):

- Module — `%ProgramFiles%\WindowsPowerShell\Modules\AdminHub` (PS 5.x) and
  `%ProgramFiles%\PowerShell\Modules\AdminHub` (PS 7); remote via `\\SERVER\C$\...`.
- Profile shim — `%SystemRoot%\System32\WindowsPowerShell\v1.0\profile.ps1` (PS 5.x,
  remote `\\SERVER\Admin$\...`) and `%ProgramFiles%\PowerShell\7\profile.ps1`
  (PS 7, remote `\\SERVER\C$\...`).

An edition that isn't installed on the target is skipped automatically (use
`-Verbose` to see which).

Existing profiles are backed up with a timestamped `.bak_` suffix before being
overwritten.

## Rollback

```powershell
.\Remove-AdminProfile.ps1 -ComputerName SRV01
```

Restores the most recent backup if one exists; otherwise removes the deployed
profile.

## Code signing

> **These scripts should be digitally signed before deployment.** Relaxing the
> execution policy to `RemoteSigned` (above) is fine for testing, but the
> production-safe option is to sign the scripts so they run under the strict
> `AllSigned` policy — and so any later tampering invalidates them. Sign **all**
> the code that runs: the module (`AdminHub.psm1`) and the `.ps1` files
> (`AdminProfile.ps1`, `Deploy-AdminProfile.ps1`, `Remove-AdminProfile.ps1`,
> `Install-UserProfile.ps1`), because `AllSigned` validates every script and
> module that loads. (`Get-ChildItem .\*.ps1, .\*.psm1` covers them.)

You need an **Authenticode code-signing certificate**. Where it must be trusted
decides which kind to use:

| Use case                          | Certificate                                                        |
|-----------------------------------|-------------------------------------------------------------------|
| Deploy across the org's servers   | A cert from your **internal/enterprise CA** (domain machines trust it via AD) |
| Distribute outside the org        | A cert from a **public CA** (DigiCert, Sectigo, etc.)             |
| Local testing only                | A **self-signed** cert (trusted only where you import it)         |

### Sign the scripts

Run from an elevated PowerShell prompt in the `AdminHub` folder. Signing appends
a signature block to the file, so **sign last** — any later edit breaks the
signature and the file must be re-signed.

```powershell
# Pick your code-signing certificate from the certificate store...
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1

# ...or load it from a .pfx file:
# $cert = Get-PfxCertificate -FilePath .\codesign.pfx

# Sign each script. -TimeStampServer keeps the signature valid after the cert
# expires; SHA256 is the modern hash algorithm.
Get-ChildItem .\*.ps1 | ForEach-Object {
    Set-AuthenticodeSignature -FilePath $_.FullName -Certificate $cert `
        -TimeStampServer http://timestamp.digicert.com -HashAlgorithm SHA256
}
```

### Verify

```powershell
Get-ChildItem .\*.ps1 |
    ForEach-Object { Get-AuthenticodeSignature $_.FullName } |
    Format-Table Path, Status, @{N='Signer';E={$_.SignerCertificate.Subject}}
```

`Status` should read `Valid`. For self-signed or internal-CA certs, target
machines must trust the signer — import the certificate (or its issuing CA) into
**Trusted Root** and **Trusted Publishers**:

```powershell
# Example: trust a self-signed/exported public cert on the local machine
Import-Certificate -FilePath .\codesign.cer -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath .\codesign.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

> Creating a self-signed cert for testing:
> ```powershell
> $cert = New-SelfSignedCertificate -Type CodeSigningCert `
>     -Subject "CN=AdminHub Code Signing" -CertStoreLocation Cert:\CurrentUser\My
> ```

## Rebranding

The banner is configurable at the top of `AdminProfile.ps1`. Replace
`$BannerLines` / `$BannerSubtitle` and set `$BannerColor`. Generate new ASCII
art with the "Standard" figlet font at <https://patorjk.com>.

## Requirements

- Windows Server (or Windows client) with PowerShell 5.1+ or PowerShell 7+
- Administrator rights to **deploy** (the deploy/remove scripts require
  elevation). The menu itself loads without elevation; only some tasks need
  admin, reachable via the menu's `[R]` relaunch option.
- An execution policy that allows the scripts to run. For testing, run
  `Set-ExecutionPolicy RemoteSigned` once from an elevated prompt (see
  **Deployment**). For production, **digitally sign the scripts** and run under
  `AllSigned` (see **Code signing**).
- Optional: the `PSWindowsUpdate` module for the "Pending Windows Updates" option
  (`Install-Module PSWindowsUpdate`)
