---
name: add-adminhub-check
description: Add a new health/diagnostic check to the AdminHub PowerShell module (AdminHub/AdminHub.psm1) so it shows up in the "[5] Full System Health Check" menu option, the "[E] Export Health Report" file, and the -RunCheck/-AsJson headless monitoring output. Use this whenever the user asks to add, wire up, or extend a health check, monitoring check, alert, or diagnostic in AdminHub — phrases like "add a check for X", "flag when Y happens", "monitor Z", "make AdminHub warn about ...", or anything that mentions Invoke-SystemHealthCheck, Get-HealthSummary, or the OK/WARN/FAIL health summary. Also use it when asked to add a brand-new menu option to AdminHub's Show-AdminMenu that reports a pass/fail-style status, since the same conventions apply.
---

# Add an AdminHub health check

AdminHub's health system has one source of truth: `Get-HealthSummary` in
`AdminHub/AdminHub.psm1` (around line 1457). It returns an array of
`[PSCustomObject]@{ Name; Status; Detail; Value }` entries, and **every**
consumer reads that same array — `Invoke-SystemHealthCheck` (menu `[5]`),
`Export-HealthReport` (menu `[E]`, writes `HealthReport_<host>_<stamp>.txt`),
and `AdminProfile.ps1 -RunCheck` / `-AsJson` (the Nagios/Zabbix-style
headless probe). **This means adding one entry to `Get-HealthSummary` wires
your check into the menu, the exported report, and the JSON monitoring
output all at once** — you don't wire those three paths separately, and you
shouldn't go looking for three places to edit.

Read `Get-HealthSummary` before writing anything: skim a few of its ~18
existing checks (Disk space, Memory, Pagefile, and Time sync are good ones)
to see the pattern in its current form, since the module evolves and this
file may drift from the examples below.

## 1. Decide: inline, or its own helper function?

- **Simple, always-applicable check** (a WMI/CIM call, a threshold, done in
  a few lines) → write it directly inline in `Get-HealthSummary`, next to
  the checks it's most related to. Disk space, Memory, and Pagefile are all
  inline.
- **Check that (a) doesn't always apply** (VM-only, domain-joined-only,
  needs an optional tool like `racadm`), **or (b) deserves its own
  standalone menu view** (like `[N]` Network or `[V]` Event Log Search), **or
  (c) needs a detailed multi-line dump in the exported report** (not just one
  summary line) → factor it into its own `Get-<Thing>Health` function
  (see `Get-TimeSyncHealth`, `Get-DnsHealth`, `Get-HardwareHealth` for the
  shape) that:
  - Returns **`$null`** when the check doesn't apply to this machine — this
    is the established "skip gracefully" signal. `Get-TimeSyncHealth`
    returns `$null` when `$env:USERDNSDOMAIN` is unset (not domain-joined);
    `Get-HardwareHealth` returns `$null` on VMs. Callers check `$null` before
    appending to `$checks`, so a skipped check produces no row at all rather
    than a fake OK/WARN.
  - Otherwise returns `[PSCustomObject]@{ Status; Detail; Value }` (add
    `Raw`/`Items` too if the exported report should show a detail table —
    see `Get-DellStorageHealth` or `Get-CertHealth`).
  - Gets called from `Get-HealthSummary` guarded by the same `$null` check,
    e.g. `if ($result) { $checks += ... }`.
  - Optionally gets its own `Show-<Thing>Health` wrapper (see
    `Show-TimeSync`) if it's worth a dedicated menu key too — that's a
    separate decision from the health-check wiring above, see step 4.

When in doubt, start inline. It's easy to extract into a helper function
later if the check grows.

## 2. Status and thresholds

Only three statuses feed the OK/WARN/FAIL rollup: `'OK'`, `'WARN'`,
`'FAIL'`. Look at an existing check that measures something similar to
yours and reuse its shape rather than inventing new thresholds from
scratch:

| Check | WARN | FAIL |
|---|---|---|
| Disk space (% used) | ≥ 80 | ≥ 90 |
| Memory (% used) | ≥ 85 | ≥ 95 |
| Pagefile (% used) | ≥ 80 | ≥ 95 |
| Time sync (offset, seconds) | ≥ 2 | ≥ 30 |
| Certificate expiry (days left) | ≤ 30 | ≤ 7 or expired |

A binary check (something either is or isn't a problem, like Default
gateway reachability or DNS resolution) just uses `'OK'`/`'FAIL'` with no
WARN tier — that's fine too, follow whichever existing check is the closer
analogy.

`Detail` is the short string shown inline (`[math]::Round(...)` for any
percentage, keep it to one line — it prints in a fixed-width table via
`Write-HealthSummary`).

`Value` is **optional** — populate it only when the check has a natural
number worth graphing (percent, seconds, a count), e.g. `Value = $memPct`.
Checks with no natural number (Pending reboot, Auto services, Network
adapters) simply omit the field. `Value` is what makes the check useful in
the `-AsJson` trend output, so add it whenever there's an obvious number.

## 3. Fail safely, don't fail loudly

`Get-HealthSummary` has a function-scope `trap { continue }` so one
throwing check can't blow up the whole summary — but don't rely on that as
your error handling. Wrap anything that calls out to WMI/CIM, an external
tool, or a network resource in its own `try`/`catch`, matching the existing
checks' style of a best-effort empty or near-empty `catch` block (this
module deliberately excludes `PSAvoidUsingEmptyCatchBlock` from
PSScriptAnalyzer for exactly this reason — see
`AdminHub/ScriptAnalyzerSettings.psd1`). The goal: a missing dependency or
an unreachable endpoint degrades your one check, never the whole report.

## 4. Only if this check needs a dedicated menu option too

Adding a row to `Get-HealthSummary` is enough by itself — it does **not**
require a new exported function or a new menu key. Only do the following if
the check is substantial enough to deserve its own standalone view (like
`[N]` Network or `[V]` Event Log Search):

1. Write the `Show-<Thing>Health` function.
2. Add it to **both** `FunctionsToExport` in `AdminHub/AdminHub.psd1` *and*
   the `Export-ModuleMember -Function` list at the bottom of
   `AdminHub/AdminHub.psm1` (~line 2147) — these two lists must match
   exactly, and `AdminHub/Tests/AdminHub.Tests.ps1` has a Pester test
   ("Export surface has not drifted") that fails the build if they don't.
3. Add a menu key in `Show-AdminMenu` (~line 1987), in the section
   (System & Diagnostics / Networking / Maintenance) it fits best, keeping
   the existing alphabetize-within-section convention.

## 5. Update AdminHub/README.md

Two spots need the new check, or the docs will describe a menu that no
longer matches the code:

1. The bulleted list under **`### Health checks`** — one bullet per check,
   naming its WARN/FAIL thresholds and any skip conditions, in the same
   style as the existing entries (e.g. the "Time sync" or "Certificate
   expiry" bullets).
2. The sample health-summary transcript near the top of the README (the
   `[FAIL]`/`[WARN]`/`[OK ]` block) — add a plausible line for your check so
   the example output stays representative. If your check adds a detail
   section to the exported report (step 1's helper-function path), also
   check whether the "`[E]` writes ... to a timestamped file" paragraph's
   list of report sections needs your section name appended.

## 6. Before you're done

This repo's CI (and the Pester suite) enforce pure-ASCII, no-BOM source
files and a clean PSScriptAnalyzer + Pester run. Use the **verify-adminhub**
skill (or run its checks manually) before considering the change finished —
don't just eyeball the diff.
