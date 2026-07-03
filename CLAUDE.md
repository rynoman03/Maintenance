# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This is a Windows systems-administration script collection, not a packaged
application. It has two parts with very different levels of rigor:

- **Repo root** — standalone, independent PowerShell scripts (Active Directory,
  TLS/SCHANNEL registry config, printer inventory, connectivity checks,
  scheduled reboot + email, Dell iDRAC management). No shared code, no tests,
  no build step. Several filenames are extensionless (`UserGroup`, `PingIt`,
  `Print Server List Print Queues`, `SystemRebootTask_and_Email`) and some
  contain spaces, so quote paths when invoking them, e.g.
  `& ".\TLS\Enable TLS 1.2 on Client and Server"`.
- **`AdminHub/`** — a proper PowerShell module with a manifest, Pester tests,
  and a CI gate. This is the actively maintained, higher-bar part of the repo.
  Treat it differently from the root-level scripts.

Everything targets Windows PowerShell 5.1 (some scripts also work on
PowerShell 7). There is no cross-platform support — commands depend on
`HKLM:` registry providers, AD cmdlets, WMI/CIM, COM automation (Excel), and
Windows-only tooling.

## AdminHub module (`AdminHub/`)

An interactive admin console profile, deployed to `AllUsersAllHosts` so every
user who opens PowerShell on a server gets a menu (banner + task list), with
the option to drop to a normal shell. It also autoloads on-demand via
`PSModulePath` in any session, including `Enter-PSSession` — no profile
required for remoting.

### Architecture

- `AdminHub.psm1` — the entire module (~2150 lines): banner, menu
  (`Show-AdminMenu`), and every task/health-check function. Functions
  generally come in `Get-*`/`Test-*` (data, no output) + `Show-*` (formats and
  prints) pairs, e.g. `Get-NetworkAdapterHealth` / `Show-NetworkStatus`.
- `AdminHub.psd1` — module manifest. `FunctionsToExport` here must exactly
  match `Export-ModuleMember` in `AdminHub.psm1` — CI and Pester both check
  this and will fail on drift. Aliases: `adminhub` -> `Show-AdminMenu`, `top`
  -> `Show-ProcessMonitor`.
- `AdminProfile.ps1` — thin shim deployed as the actual profile.ps1. Imports
  the module and calls `Show-AdminMenu`, but **only in an interactive
  console** (remoting/`-NonInteractive`/redirected stdin load silently). Also
  doubles as a Nagios/Zabbix-style health probe via `-RunCheck`
  (`-AsJson`, `-Quiet`), exit codes 0=OK/1=WARN/2=FAIL/3=UNKNOWN.
- `Deploy-AdminProfile.ps1` / `Remove-AdminProfile.ps1` — install/uninstall to
  `PSModulePath` + the AllUsersAllHosts profile path, local or remote (via
  `\\SERVER\Admin$` / `\\SERVER\C$`). Requires elevation
  (`#Requires -RunAsAdministrator`). Remove restores the most recent
  timestamped `.bak_` backup if one exists.
- `Install-UserProfile.ps1` — per-user install (no admin) to
  `Documents\WindowsPowerShell\profile.ps1`.
- `ScriptAnalyzerSettings.psd1` — lint rules for CI; the `ExcludeRules` block
  documents *why* each exclusion is deliberate (interactive `Write-Host` UI,
  established plural-noun command names, custom `Read-Host` confirmation
  pattern instead of `-WhatIf`/`-Confirm`, intentional empty catch blocks for
  best-effort hardware probes). Read it before "fixing" one of those patterns.
- `Tests/AdminHub.Tests.ps1` — Pester 5 tests covering: manifest validity,
  module import, export-surface drift between `.psd1` and `.psm1`, and that
  every shipped `.ps1`/`.psm1`/`.psd1` is **pure ASCII with no BOM** (Windows
  PowerShell 5.1 misreads UTF-8-with-BOM).

### Key invariants when editing AdminHub

- **Encoding**: keep all `AdminHub/*.ps1`, `*.psm1`, `*.psd1` files pure
  ASCII, no BOM. Pester enforces this and CI will fail otherwise.
- **Export surface**: if you add/remove/rename a public function, update both
  `FunctionsToExport` in `AdminHub.psd1` and the corresponding
  `Export-ModuleMember` entry in `AdminHub.psm1`. They must match exactly.
- **Menu additions**: the menu is grouped into System & Diagnostics,
  Networking, Maintenance sections in `Show-AdminMenu`; keys within a section
  are alphabetized by convention (see git history: "alphabetize the letter
  options within each menu section").
- **Critical-process guard**: process/service kill paths
  (`Stop-ProcessInteractive`, `Restart-ServiceByName`'s kill option) must keep
  refusing to terminate PIDs hosting kernel-critical services, and must
  re-validate the PID immediately before killing (guards against PID reuse).
  Don't weaken this without understanding why it exists (README "Manage a
  service" / "Kill a Process" sections).
- **VM/hardware-specific checks**: Dell-only checks (`Get-DellStorageHealth`,
  hardware temp/PSU) require local `racadm` and PowerEdge 12th-gen+
  (`racadm storage` support starts at iDRAC7 fw 1.30.30+); they must degrade
  to "skipped/unsupported" rather than fail on VMs or non-Dell/older hardware.
- **Non-interactive safety**: anything using `Read-Host` or launching the menu
  must stay gated so it never blocks a remoting/scheduled-task/`-NonInteractive`
  session (see `AdminProfile.ps1`'s interactivity check).
- Banner ASCII art is generated with the "Standard" figlet font at
  patorjk.com (see `AdminProfile.ps1`'s `$BannerLines`).

### Common commands (run from `AdminHub/`)

```powershell
# Install lint/test tooling (first time)
Install-Module PSScriptAnalyzer, Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

# Lint (must be run under/against these settings; CI uses Windows PowerShell 5.1)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\ScriptAnalyzerSettings.psd1

# Run all tests
Invoke-Pester -Path .\Tests

# Run a single test file
Invoke-Pester -Path .\Tests\AdminHub.Tests.ps1

# Run tests matching a name/tag
Invoke-Pester -Path .\Tests -FullNameFilter '*ASCII*'

# Local install for personal use (no admin)
.\Install-UserProfile.ps1                 # Windows PowerShell 5.x
.\Install-UserProfile.ps1 -AllEditions    # also PowerShell 7

# Deploy to a server (elevated PowerShell required)
.\Deploy-AdminProfile.ps1
.\Deploy-AdminProfile.ps1 -ComputerName SRV01,SRV02,SRV03 -Force

# Roll back a deployment
.\Remove-AdminProfile.ps1 -ComputerName SRV01

# Headless health check (Nagios-style; exit code 0/1/2/3)
powershell -NoProfile -File AdminProfile.ps1 -RunCheck
powershell -NoProfile -File AdminProfile.ps1 -RunCheck -AsJson
```

CI (`.github/workflows/adminhub-ci.yml`) runs PSScriptAnalyzer + Pester on
Windows PowerShell 5.1 (not `pwsh`), scoped to pushes/PRs touching
`AdminHub/**`. It fails the build on any Error/Warning from the analyzer
(after `ExcludeRules`) or any Pester failure.

## Root-level scripts

These are independent tools with no shared framework — read each one's
section in [README.md](README.md) before changing it. Notable ones:

- `UserGroup` — interactive AD group creation (owner group + main group +
  `ManagedBy` + membership). Contains a hardcoded OU path placeholder.
- `TLS/` — three scripts that write `SCHANNEL`/`.NET` registry keys to
  enable/disable TLS 1.0/1.1/1.2/1.3. Changes are machine-wide and can affect
  app compatibility; a restart is typically required.
- `Print Server List Print Queues` — builds an Excel workbook via WMI +
  Excel COM automation; requires Excel installed and opens it visibly.
- `IdracManager.ps1` / `IdracManager.cmd` — Dell iDRAC manager over Redfish
  HTTPS (power state, health, firmware, thermal, users, security audit).
  `.cmd` launcher prefers `pwsh.exe`, falls back to `powershell.exe`.
- `Sendmail.ps1` + `SystemRebootTask_and_Email` — paired scripts: one sends an
  SMTP notification, the other registers a scheduled reboot task that calls it.
- `PingIt` — reads `servers.txt` (one hostname per line, not checked in) and
  `Test-Connection`s each.

Scripts in this tier commonly contain environment-specific placeholders
(AD OU paths, print server names, SMTP settings, `DOMAIN\user`, hardcoded
script paths, iDRAC hosts/credentials) that must be edited before use — there
is no config file layer. There is no lint/test gate for this tier (unlike
`AdminHub/`).

## General safety notes

Several scripts make machine-wide, hard-to-reverse changes: `HKLM:` registry
edits, AD object creation, scheduled reboots, service/process kills. Test in
a lab/non-production target before running against production. Scripts here
are not digitally signed; running them may require
`Set-ExecutionPolicy RemoteSigned` once per machine (production deployments
should be signed and run under `AllSigned` — see the AdminHub README's "Code
signing" section for the full process).
