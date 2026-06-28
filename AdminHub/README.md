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
| N   | Network Adapters            | Read        |
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
- **Uptime** — time since last boot

In addition to the summary verdict, `[5]` prints the **most recent System-log
errors** (up to 20 Critical/Error events from the last 24 hours: time, level,
source, event ID, and first line of the message) so you can see the actual
events on screen, not just the count.

`[5]` also lists each connected adapter's link speed and discard/error counts
(also available on its own via `[N]`).

`[E]` writes the summary plus supporting detail tables (disk, physical-disk
health, stopped services, network adapters, recent errors, top memory, active
sessions) to a timestamped file at
`C:\AdminReports\HealthReport_<COMPUTERNAME>_<timestamp>.txt`.

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

The profile is written to the **AllUsersAllHosts** path for each installed
PowerShell edition:

- Windows PowerShell 5.x: `%SystemRoot%\System32\WindowsPowerShell\v1.0\profile.ps1`
  (remote: `\\SERVER\Admin$\System32\...`)
- PowerShell 7+: `%ProgramFiles%\PowerShell\7\profile.ps1`
  (remote: `\\SERVER\C$\Program Files\PowerShell\7\...`)

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
> `.ps1` files (`AdminProfile.ps1`, `Deploy-AdminProfile.ps1`,
> `Remove-AdminProfile.ps1`), because `AllSigned` validates every script that
> runs.

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
