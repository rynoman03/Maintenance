#
# PSScriptAnalyzer settings for AdminHub.
#
# Used by the CI workflow (.github/workflows/adminhub-ci.yml) and locally:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\ScriptAnalyzerSettings.psd1
#
# The gate fails on any Error or Warning that is NOT in ExcludeRules below. The
# excluded rules are deliberate design choices for this module, not oversights.
#
@{
    # Only Error/Warning fail the build. Information-level rules (e.g.
    # PSProvideCommentHelp) are surfaced by analyzers but do not break CI; adding
    # comment-based help to every public function is tracked as a separate task.
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # AdminHub is an INTERACTIVE console tool - colored menus and status output
        # are written with Write-Host by design (they are UI, not pipeline data).
        'PSAvoidUsingWriteHost',

        # The public command surface uses established plural-noun names
        # (Get-PendingUpdates, Get-ActiveSessions, Get-TopResourceUsers, ...).
        # Renaming them would break the manifest and every caller.
        'PSUseSingularNouns',

        # The state-changing menu helpers (Restart-ServiceByName, Stop-ProcessInteractive,
        # Restart-ComputerInteractive, Invoke-DiskCleanup) implement their OWN explicit
        # Read-Host confirmations rather than the -WhatIf/-Confirm ShouldProcess pattern,
        # because they are driven from an interactive text menu.
        'PSUseShouldProcessForStateChangingFunctions',

        # Empty catch blocks are an intentional best-effort pattern here: hardware /
        # WMI / P-Invoke probes that are simply absent on many systems are swallowed
        # so one missing data source never aborts a health summary.
        'PSAvoidUsingEmptyCatchBlock',

        # False positive: PSSA does not follow PowerShell's dynamic scoping, so it
        # flags script-level parameters (e.g. -Force in Deploy-AdminProfile.ps1) that
        # are read inside nested functions as "unused" when they are in fact used.
        'PSReviewUnusedParameter'
    )
}
