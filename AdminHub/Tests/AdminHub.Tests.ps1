# Pester v5 tests for the AdminHub module.
#
# Run locally:  Invoke-Pester -Path .\Tests
# CI runs these under Windows PowerShell 5.1 (the module's target runtime).
#
# These cover the failure modes that break a PowerShell module silently:
#   * a manifest that no longer parses / matches the code,
#   * an export surface that has drifted between the .psd1 (FunctionsToExport)
#     and the .psm1 (Export-ModuleMember), and
#   * the pure-ASCII / no-BOM encoding the module depends on (Windows
#     PowerShell 5.1 mis-reads UTF-8-with-BOM script files).

$script:ModuleRoot = Split-Path -Parent $PSScriptRoot
$script:Manifest   = Join-Path $ModuleRoot 'AdminHub.psd1'
$script:ModuleFile = Join-Path $ModuleRoot 'AdminHub.psm1'

# Built at discovery time so -ForEach can fan out one test per source file.
$script:FileCases = @(
    Get-ChildItem -Path $ModuleRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
)

Describe 'Module manifest' {
    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $Manifest -ErrorAction Stop } | Should -Not -Throw
    }
    It 'has RootModule AdminHub.psm1' {
        (Test-ModuleManifest -Path $Manifest).RootModule | Should -Be 'AdminHub.psm1'
    }
    It 'targets Windows PowerShell 5.1 or later' {
        (Test-ModuleManifest -Path $Manifest).PowerShellVersion | Should -BeGreaterOrEqual ([version]'5.1')
    }
    It 'declares the adminhub and top aliases' {
        $aliases = (Test-ModuleManifest -Path $Manifest).ExportedAliases.Keys
        $aliases | Should -Contain 'adminhub'
        $aliases | Should -Contain 'top'
    }
}

Describe 'Module import' {
    BeforeAll {
        Remove-Module AdminHub -Force -ErrorAction SilentlyContinue
        $script:Imported    = Import-Module $Manifest -Force -PassThru -ErrorAction Stop
        $script:ManifestFns = @((Test-ModuleManifest -Path $Manifest).ExportedFunctions.Keys)
    }
    AfterAll { Remove-Module AdminHub -Force -ErrorAction SilentlyContinue }

    It 'imports without error' {
        $Imported | Should -Not -BeNullOrEmpty
    }
    It 'exports every function the manifest lists' {
        foreach ($fn in $ManifestFns) {
            Get-Command -Module AdminHub -Name $fn -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$fn is in FunctionsToExport and must resolve"
        }
    }
    It 'maps the adminhub alias to Show-AdminMenu' {
        (Get-Alias adminhub).ResolvedCommandName | Should -Be 'Show-AdminMenu'
    }
    It 'maps the top alias to Show-ProcessMonitor' {
        (Get-Alias top).ResolvedCommandName | Should -Be 'Show-ProcessMonitor'
    }
    It 'exports the three triage commands' {
        foreach ($fn in 'Show-EventLogSearch', 'Stop-ProcessInteractive', 'Restart-ComputerInteractive') {
            Get-Command -Module AdminHub -Name $fn -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because "$fn should be part of the public surface"
        }
    }
}

Describe 'Export surface has not drifted' {
    BeforeAll {
        # Import the .psm1 directly: its exported functions reflect Export-ModuleMember
        # alone, independent of the manifest. Comparing the two lists catches a name
        # added to one but not the other.
        Remove-Module AdminHub -Force -ErrorAction SilentlyContinue
        $psm = Import-Module $ModuleFile -Force -PassThru -ErrorAction Stop
        $script:Psm1Fns     = @($psm.ExportedFunctions.Keys)
        $script:ManifestFns = @((Test-ModuleManifest -Path $Manifest).ExportedFunctions.Keys)
    }
    AfterAll { Remove-Module AdminHub -Force -ErrorAction SilentlyContinue }

    It 'lists the same functions in the .psd1 and the .psm1' {
        $diff = Compare-Object -ReferenceObject ($ManifestFns | Sort-Object) `
                               -DifferenceObject ($Psm1Fns | Sort-Object)
        $diff | Should -BeNullOrEmpty -Because (
            "FunctionsToExport (.psd1) and Export-ModuleMember (.psm1) must match. " +
            "Drift: " + (($diff | ForEach-Object { '{0}{1}' -f $_.SideIndicator, $_.InputObject }) -join ', '))
    }
}

Describe 'Source file encoding' {
    It '<Name> is pure ASCII (no byte > 127)' -ForEach $FileCases {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count |
            Should -Be 0 -Because "$Name must be pure ASCII for Windows PowerShell 5.1"
    }
    It '<Name> has no UTF-8 BOM' -ForEach $FileCases {
        $bytes  = [System.IO.File]::ReadAllBytes($Path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $hasBom | Should -BeFalse -Because "$Name must be saved without a byte-order mark"
    }
}
