---
name: verify-adminhub
description: Run AdminHub's local CI gate (PSScriptAnalyzer lint + Pester tests) against AdminHub/ before pushing or committing changes there, mirroring .github/workflows/adminhub-ci.yml exactly. Use this whenever the user asks to verify, check, lint, test, or validate changes to the AdminHub module, wants to know if AdminHub CI will pass, or is about to commit/push a change under AdminHub/ (add a health check, a menu option, a new function, an edit to AdminHub.psm1/.psd1) — check this before declaring that work done. Requires Windows PowerShell (powershell.exe) or PowerShell 7 (pwsh) to actually run; if neither is available in the current environment, this skill still applies — its job then is to say so clearly and hand back the exact commands to run instead of silently skipping validation.
---

# Verify AdminHub before pushing

AdminHub is Windows-only PowerShell. This skill's whole point is to run the
*same* two gates CI runs (`.github/workflows/adminhub-ci.yml`) — PSScriptAnalyzer
and Pester — so a failure surfaces here instead of after a push. Never report
"looks good" based on reading the diff alone; these are the actual checks CI
enforces, and several of the things they catch (export-surface drift, ASCII
encoding) are not visible from source review.

## 0. Check whether PowerShell is even available — don't skip silently

```bash
command -v pwsh 2>/dev/null
command -v powershell 2>/dev/null || command -v powershell.exe 2>/dev/null
```

- **Neither found**: Stop here and say so explicitly — do not report a pass,
  a skip, or move on quietly. Tell the user this environment has no
  PowerShell, so AdminHub can't be validated from here, and hand them the
  exact commands from step 2/3 to run themselves (in a Windows PowerShell
  session, or via a Windows CI run / `workflow_dispatch` on
  `adminhub-ci.yml`). This is expected in most non-Windows sandboxes
  (including this one, most likely) — it is not a bug in the skill.
- **`powershell.exe` (Windows PowerShell 5.1) found**: prefer it. CI runs
  under `shell: powershell` specifically (Windows PowerShell 5.1, the
  module's declared minimum and target runtime), not `pwsh` 7 — so this is
  the closest local match to what CI actually does.
- **Only `pwsh` (PowerShell 7) found**: use it, but say plainly that this is
  PowerShell 7, not the Windows PowerShell 5.1 CI actually runs under —
  useful as a fast signal, but a clean run here doesn't guarantee CI is
  clean (5.1 and 7 differ in module compat and, occasionally, parsing). The
  Pester "no BOM / pure ASCII" test exists specifically because *Windows
  PowerShell 5.1* misreads UTF-8-with-BOM files that PowerShell 7 handles
  fine — so that test matters most in exactly the case pwsh alone can mask.

## 1. Make sure the modules are installed

CI installs these exact versions (see the workflow's "Install
PSScriptAnalyzer and Pester" step) — match them locally so a version-related
result doesn't diverge from CI:

```powershell
Install-Module PSScriptAnalyzer -MinimumVersion 1.21.0 -Force -Scope CurrentUser
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
```

(The `-SkipPublisherCheck` on Pester matters: Windows ships an old in-box
Pester 3.4 that conflicts with 5.x otherwise.) If both modules are already
present at sufficient versions, skip reinstalling.

## 2. Run PSScriptAnalyzer

From the `AdminHub/` directory:

```powershell
Import-Module PSScriptAnalyzer
$results = Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\ScriptAnalyzerSettings.psd1
```

`ScriptAnalyzerSettings.psd1` fails the build on any `Error` or `Warning`
that isn't in its `ExcludeRules` list — read that file if a result surprises
you, since several rules (`PSAvoidUsingWriteHost`, `PSUseSingularNouns`,
`PSUseShouldProcessForStateChangingFunctions`,
`PSAvoidUsingEmptyCatchBlock`, `PSReviewUnusedParameter`) are excluded
*deliberately*, with comments explaining why, not by oversight — don't
"fix" those by reflex. Anything else in `$results` is a real gate failure:
show it (`$results | Format-Table -AutoSize`) and fix it before continuing.

## 3. Run Pester

Still from `AdminHub/`, matching CI's configuration (throws on any
failure, detailed output):

```powershell
Import-Module Pester -MinimumVersion 5.0
$config = New-PesterConfiguration
$config.Run.Path         = './Tests'
$config.Run.Throw        = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
```

(Simpler `Invoke-Pester -Path .\Tests` also works for a quick check, but use
the config above when you need CI-equivalent throw-on-failure behavior.)

`Tests/AdminHub.Tests.ps1` checks three independent things — when it fails,
identify which:

1. **Manifest validity** — `AdminHub.psd1` parses and declares the right
   `RootModule`/`PowerShellVersion`/aliases.
2. **Export surface drift** — `FunctionsToExport` in `AdminHub.psd1` must
   list *exactly* the same functions as `Export-ModuleMember -Function` in
   `AdminHub.psm1`. This is the one most likely to break after adding a new
   public function: it's easy to export from one and forget the other.
3. **Source encoding** — every shipped `.ps1`/`.psm1`/`.psd1` must be pure
   ASCII with no UTF-8 BOM (Windows PowerShell 5.1 requirement). A stray
   non-ASCII character (smart quotes/en-dashes pasted from a doc, an emoji)
   or a BOM added by some editors will fail this per-file.

## 4. Report the result plainly

State clearly: which PowerShell was used (and whether it's the 5.1-vs-7
caveat from step 0), whether PSScriptAnalyzer was clean, and whether Pester
passed — with the specific failing rule names / test names if not, not just
"something failed." If everything passed, say so plainly too; this is the
signal the user needs before pushing.
