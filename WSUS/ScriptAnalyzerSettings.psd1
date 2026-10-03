#
# PSScriptAnalyzer settings for WsusManager.
#
# Used by .github/workflows/wsus-ci.yml and locally:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\ScriptAnalyzerSettings.psd1
#
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The menu, launcher and build script are interactive console UI.
        'PSAvoidUsingWriteHost',

        # Empty catch blocks are deliberate best-effort probes inside the remote
        # client-status script (ConfigMgr, WUA COM, registry) that are simply
        # absent on many machines.
        'PSAvoidUsingEmptyCatchBlock',

        # PSSA does not follow dynamic scoping: parameters of the remote script
        # blocks and of the launcher are read inside nested blocks / switch arms.
        'PSReviewUnusedParameter',

        # Assigned-but-unused false positives for variables consumed by
        # nested script blocks invoked with & (e.g. $wsus in the WSUS query).
        'PSUseDeclaredVarsMoreThanAssignments',

        # The Pester tests pass made-up computer names ('srv1') to pure functions.
        'PSAvoidUsingComputerNameHardcoded'
    )
}
