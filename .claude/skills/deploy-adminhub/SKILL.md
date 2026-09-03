---
name: deploy-adminhub
description: Deploy, redeploy, or roll back the AdminHub PowerShell module (AdminHub/) to the local server or a list of remote servers using Deploy-AdminProfile.ps1 / Remove-AdminProfile.ps1, or install it per-user with Install-UserProfile.ps1. Use this whenever the user wants to deploy, install, push out, roll back, remove, or uninstall AdminHub on one or more servers, mentions Deploy-AdminProfile.ps1/Remove-AdminProfile.ps1/Install-UserProfile.ps1 by name, or asks things like "get AdminHub onto SRV01", "roll this back", "install my profile for just me". Covers the pre-flight verification gate, elevation and reachability requirements, the -ComputerName/-Force flags, what does and doesn't get backed up, and code-signing status.
---

# Deploy / roll back AdminHub

`AdminHub/Deploy-AdminProfile.ps1` installs two things per PowerShell
edition present on each target: the **module** (`AdminHub.psm1`/`.psd1`,
copied under `PSModulePath` so commands autoload everywhere, including
`Enter-PSSession`) and a tiny **profile shim** (at the AllUsersAllHosts
path, so an interactive console auto-shows the menu). Both scripts require
`#Requires -RunAsAdministrator` — check the invoking session is elevated
before running either, locally or remote.

## 1. Verify before you deploy

Never deploy code that hasn't passed the CI gate — a deploy pushes straight
to `PSModulePath` on every target with no build step to catch a bad module
in between. Run the **verify-adminhub** skill (PSScriptAnalyzer + Pester)
first, and only proceed once it reports clean. If verify-adminhub can't run
here (no PowerShell in this environment), say so and hand deployment back to
the user to run themselves rather than skipping the check silently.

## 2. Deploying

```powershell
# Local server
.\Deploy-AdminProfile.ps1

# One or more remote servers
.\Deploy-AdminProfile.ps1 -ComputerName SRV01,SRV02,SRV03 -Force
```

What to know before running this:

- **Reachability**: for each remote target, the script checks
  `\\$Computer\Admin$` first and **skips** (with a warning, not a hard
  failure) any server it can't reach — so a typo'd or offline hostname in a
  `-ComputerName` list doesn't abort the whole batch. Check the output for
  skipped hosts after a multi-server run.
- **Per-edition, best-effort install**: Windows PowerShell 5.1 is assumed
  always present, but the PowerShell 7 module/profile path is installed
  only if `pwsh.exe` is actually found on that target — an edition that
  isn't installed is silently skipped (use `-Verbose` to see which). Don't
  treat a missing PS7 install on a target as a deploy failure; it's
  expected on servers that don't have PS7.
- **`-Force`**: without it, an existing profile at the destination prompts
  `Y/N` before overwriting — fine for one server, impractical across a
  `-ComputerName` list. Use `-Force` for multi-server / non-interactive
  runs, but know what it skips: the confirmation, not the backup (see
  next point).
- **Backups happen automatically, and are smart about re-deploys**: an
  existing profile is backed up to a timestamped `<path>.bak_<stamp>`
  *unless* it's already an AdminHub shim — so redeploying an update
  doesn't pile up redundant backups, but the **first** deploy onto a
  server that had some other custom profile always preserves it first.
  The **module** files themselves are not versioned/backed up on deploy —
  only the profile shim is. If you need to recover a previous module
  version, that comes from git history, not from anything the deploy
  script keeps on the target.
  - **This has a sharp edge for rollback, worth stating up front rather
    than discovering it during an incident**: redeploying an *update* to a
    server that already has AdminHub creates **no new backup** (its shim
    already says "AdminHub," so the skip-backup branch fires). That means
    if the new module turns out bad, `Remove-AdminProfile.ps1` on that
    server does **not** revert it to the version it had five minutes ago —
    it restores whatever (if anything) predates AdminHub entirely on that
    box, or just removes AdminHub if there was never a prior profile. See
    step 4 below: "undo AdminHub" and "go back to yesterday's AdminHub"
    are two different operations, and only the first one is what
    `Remove-AdminProfile.ps1` actually does after an update-in-place.
- **Execution policy / signing**: these scripts aren't signed by default.
  If a target blocks them ("running scripts is disabled on this system"),
  that machine needs `Set-ExecutionPolicy RemoteSigned` once (elevated).
  For a production rollout, the README's "Code signing" section documents
  signing the module + all four `.ps1` files with an Authenticode
  certificate so they run under `AllSigned` instead — if the user is
  deploying to production and the scripts aren't signed yet, flag this
  rather than assuming `RemoteSigned` is good enough long-term.

## 3. Confirming it landed

After a deploy, a quick way to confirm a target picked it up without a full
login: `Invoke-Command -ComputerName <target> { Get-Module -ListAvailable
AdminHub }` (or, once confirmed, `Enter-AdminSession <target>` to open the
live menu remotely). A target that didn't get the module shows nothing
here — re-check reachability and the per-edition skip logic above before
assuming something is broken.

## 4. Rolling back

```powershell
.\Remove-AdminProfile.ps1 -ComputerName SRV01,SRV02
```

This restores the **most recent** `.bak_*` backup if one exists (and
deletes older backups so they don't accumulate), or deletes the profile
shim outright if there was never a backup (i.e., AdminHub was the first
profile on that box). It also deletes the module folder entirely — there
is no "previous version" of the module to roll back to on the target
itself, only "module present" or "module absent."

**These are two different requests — don't conflate them:**

- **"Get AdminHub off this box, whatever was there before (if anything)"**
  → `Remove-AdminProfile.ps1` does exactly this, and only this.
- **"Put this box back on the AdminHub version it had before today's
  deploy"** → this is a **redeploy of an older commit**, not a removal.
  `Remove-AdminProfile.ps1` cannot do it when the target already had
  AdminHub before the bad push, because (per step 2 above) that push
  created no new backup to restore *to* — the newest `.bak_*`, if any,
  predates AdminHub ever landing there at all. Check out the last-known-
  good commit of `AdminHub/` and run `.\Deploy-AdminProfile.ps1
  -ComputerName <target> -Force` from it instead; don't run
  `Remove-AdminProfile.ps1` first, the redeploy just overwrites the
  module files directly.

If the user's phrasing is ambiguous ("roll it back," "undo this"), ask
which of the two they mean before running either — they produce visibly
different end states on a box that already had AdminHub.

## 5. Per-user install (no admin, single account)

For "just get this on my own account" rather than a server-wide install,
that's `Install-UserProfile.ps1`, not `Deploy-AdminProfile.ps1` — it needs
no elevation and only touches `Documents\WindowsPowerShell\profile.ps1`
(add `-AllEditions` for the PowerShell 7 profile too). Point the user here
if they're asking about their own workstation rather than a server fleet.
