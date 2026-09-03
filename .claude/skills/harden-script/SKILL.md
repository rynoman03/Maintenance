---
name: harden-script
description: Harden one of this repo's ad hoc maintenance scripts (ActiveDirectory/UserGroup.ps1, Networking/PingIt.ps1, Notifications/Sendmail.ps1 and SystemRebootTask_and_Email.ps1, Printing/Get-PrintQueueInventory.ps1, iDRAC/IdracManager.ps1, or the TLS/ scripts) up to production-safe quality, following the repo's own documented "Script hardening" checklist. Use this whenever the user asks to harden, clean up, productionize, parameterize, or "make safe" one of these scripts, wants placeholders (OU paths, server names, SMTP settings, domain users) turned into real parameters, wants -WhatIf/-Confirm added to something destructive, or references the README's "Future improvement ideas" / "Script hardening" section. Do not use this for AdminHub/ — that module already follows these conventions; use add-adminhub-check or verify-adminhub there instead.
---

# Harden a maintenance script

The scripts outside `AdminHub/` — grouped into `ActiveDirectory/`,
`Networking/`, `Notifications/`, `Printing/`, `iDRAC/`, and `TLS/` — were
written as quick one-off admin tools: hard-coded placeholder values and
little to no error handling. The root `README.md`'s own "Script hardening"
and "Future improvement ideas" sections lay out exactly what "done" looks
like for this repo; this skill is that checklist made concrete.

For a worked example of the target style already in this repo, look at
**`iDRAC/IdracManager.ps1`**: typed `param()` block with
`[ValidateSet(...)]`, `[CmdletBinding(SupportsShouldProcess = $true)]`,
`Set-StrictMode`, a `Get-Credential` fallback instead of a plaintext
password parameter, a timestamped log file written through one small
logging helper, and `$PSCmdlet.ShouldProcess(...)` with
`ConfirmImpact = 'High'` gating the one genuinely destructive action (a
power reset). It's the most-hardened script in the repo — mirror its shape
rather than inventing a new one. `ActiveDirectory/UserGroup.ps1` has
already been brought up to this bar too (typed params, `ShouldProcess`,
try/catch, its own logging helper) and is a second, slightly simpler
reference if `IdracManager.ps1` feels like a lot to absorb at once.

## The checklist

Work through these in order; not every script needs every item (a read-only
script like `Networking/PingIt.ps1` has no destructive action to gate, for
instance) — apply what's relevant and skip what isn't rather than padding
the script.

1. **Give it a `.ps1` extension and put it in the right folder.** Every
   script currently in the repo already has both, but if you're hardening
   something newly added, follow the existing grouping (AD scripts under
   `ActiveDirectory/`, connectivity under `Networking/`, unattended
   automation under `Notifications/`, printer tooling under `Printing/`,
   Dell hardware under `iDRAC/`) rather than leaving it loose at the repo
   root. Use `git mv <name> <folder>/<name>.ps1` so history follows the
   file, and update every reference to the old path — the root
   `README.md`'s file table, its "Script notes" section, and any
   cross-reference from another script (e.g.
   `Notifications/SystemRebootTask_and_Email.ps1` invokes `sendmail.ps1`
   by path).

2. **Replace hard-coded placeholders with real `param()` values.** The
   root README explicitly calls out which values are placeholders needing
   replacement before use (AD OU paths like `OU=Groups,DC=domain,DC=com`,
   print server names, SMTP server/sender/recipient, `DOMAIN\user`,
   hard-coded script paths like `C:\scripts\sendmail.ps1`). Turn each into
   a parameter with a sensible default (or `Mandatory = $true` if there's
   no safe default) instead of a value someone has to remember to edit in
   the script body — that's the single biggest gap between these scripts
   and something safe to run twice, by two different people, without
   re-reading the source first.

3. **Add `[CmdletBinding()]` and `Set-StrictMode -Version Latest` /
   `$ErrorActionPreference = 'Stop'`.** Several of these scripts still
   don't declare these, so a typo'd variable or a failed cmdlet call can
   silently continue instead of surfacing. `iDRAC/IdracManager.ps1`,
   `ActiveDirectory/UserGroup.ps1`, and AdminHub's deploy scripts all start
   this way — match that.

4. **Wrap fallible operations in `try`/`catch` with a clear message.**
   `Test-Connection`, `New-ADGroup`/`Add-ADGroupMember`, the Excel COM
   automation in the print-queue script, and the SMTP send in
   `Notifications/Sendmail.ps1` can all fail for reasons the caller needs
   to see (server down, AD permission denied, Excel not installed, SMTP
   relay refused). Match `ActiveDirectory/UserGroup.ps1`'s pattern, which
   already does this for every AD write.

5. **Gate destructive or wide-blast-radius actions behind
   `SupportsShouldProcess` (or an explicit confirm prompt).** Creating AD
   groups, rebooting a machine
   (`Notifications/SystemRebootTask_and_Email.ps1`), and changing
   TLS/SCHANNEL registry keys (`TLS/`) all affect production state or
   availability. Add `[CmdletBinding(SupportsShouldProcess = $true)]` and
   gate the actual mutation with
   `if ($PSCmdlet.ShouldProcess($target, $action)) { ... }`, the same
   mechanism `Deploy-AdminProfile.ps1` and `Remove-AdminProfile.ps1`
   already use — this gets `-WhatIf`/`-Confirm` for free rather than
   hand-rolling another `Read-Host "...? [Y/N]"` prompt. `IdracManager.ps1`'s
   `ConfirmImpact = 'High'` on its one destructive action is the right
   precedent for a reboot or a registry change.

6. **Add logging for anything unattended.** `Notifications/Sendmail.ps1`
   and `Notifications/SystemRebootTask_and_Email.ps1` are explicitly meant
   to run from Task Scheduler with no one watching — a failure there needs
   to leave a trace. `IdracManager.ps1`'s pattern (one small `Write-Log`
   helper, timestamped log file, called from every significant step via
   `Add-Content`) is the model; a scheduled/headless script with no log at
   all is the thing most likely to fail silently in production.

7. **Document required permissions and update the README's "Script
   notes."** Once a script takes real parameters instead of placeholders,
   its README entry (the per-script subsection under "Script notes," plus
   its row in the file table) needs to describe the parameters, not the
   placeholders-to-edit workflow. Note what account/permissions running it
   actually needs (AD group-creation rights, print-server query access,
   SMTP relay access, local admin for TLS/registry changes) — this repo's
   README already does this well for `IdracManager.ps1` and
   `UserGroup.ps1`; match that level of detail for whichever script you
   hardened.

## Validating the result

There is **no CI gate** for these scripts — `.github/workflows/adminhub-ci.yml`
is scoped to `AdminHub/**` only, and there's no `ScriptAnalyzerSettings.psd1`
or Pester suite outside it. So "hardened" here means checked by hand
(and by PSScriptAnalyzer if it's available), not "passes CI":

- If PowerShell is available, run `Invoke-ScriptAnalyzer -Path <script>`
  with PSScriptAnalyzer's *default* rule set (there's no repo-specific
  settings file the way AdminHub has) as a sanity pass, and read the
  output rather than assuming clean.
- If it isn't available (as in most non-Windows sandboxes), say so plainly
  rather than claiming a check that didn't happen — same principle
  verify-adminhub follows for AdminHub, just without a settings file or
  Pester suite to point to here.
- Either way, re-read the hardened script against the checklist above one
  more time before calling it done — a param block with no validation, or
  a `try`/`catch` with an empty catch that isn't actually meant to be
  best-effort (unlike AdminHub's deliberate empty-catch pattern), are the
  two most common half-finished states.
