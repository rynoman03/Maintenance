# Pester v5 tests for WsusManager.
#
# Run locally:  Invoke-Pester -Path .\Tests
#
# These need no WSUS server and no remote computers: they cover the manifest
# and export surface, file encoding, the registry baseline (loading, tokens,
# value comparison, compliance roll-up), the reboot-report merge, target
# resolution, report export, and the single-file build used for the exe.

$script:ModuleRoot = Split-Path -Parent $PSScriptRoot
$script:Manifest = Join-Path $ModuleRoot 'WsusManager.psd1'
$script:ModuleFile = Join-Path $ModuleRoot 'WsusManager.psm1'

$script:FileCases = @(
    Get-ChildItem -Path $ModuleRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.json' |
        Where-Object { $_.FullName -notmatch '[\\/]dist[\\/]' } |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
)

Describe 'Module manifest' {
    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $Manifest -ErrorAction Stop } | Should -Not -Throw
    }
    It 'targets Windows PowerShell 5.1 or later' {
        (Test-ModuleManifest -Path $Manifest).PowerShellVersion | Should -BeGreaterOrEqual ([version]'5.1')
    }
}

Describe 'Module import and exports' {
    BeforeAll {
        Remove-Module WsusManager -Force -ErrorAction SilentlyContinue
        $script:Imported = Import-Module $Manifest -Force -PassThru -ErrorAction Stop
    }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'imports without error' {
        $Imported | Should -Not -BeNullOrEmpty
    }
    It 'exports exactly what the manifest lists' {
        $manifestFns = @((Test-ModuleManifest -Path $Manifest).ExportedFunctions.Keys) | Sort-Object
        $exported = @($Imported.ExportedFunctions.Keys) | Sort-Object
        $exported | Should -Be $manifestFns
    }
    It 'gives every state-changing command -WhatIf support' {
        foreach ($name in 'Invoke-WsusManagerCheckIn', 'Invoke-WsusManagerUpdateInstall', 'Restart-WsusManagerComputer', 'Set-WsusManagerClientRegistry') {
            (Get-Command $name).Parameters.Keys | Should -Contain 'WhatIf' -Because "$name changes client state"
        }
    }
    It 'refuses WSUS queries before connecting' {
        { Get-WsusManagerGroup } | Should -Throw '*Not connected*'
    }
}

Describe 'File encoding' {
    It '<Name> is ASCII without a BOM' -ForEach $FileCases {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Registry baseline' {
    BeforeAll {
        Import-Module $Manifest -Force
        $script:BaselineFile = Join-Path $ModuleRoot 'WsusClientBaseline.json'
        $script:Baseline = Import-WsusManagerBaseline -Path $BaselineFile
        $script:Resolved = @(Resolve-WsusManagerBaseline -Settings $Baseline.Settings -Tokens @{ WsusServerUrl = 'http://wsus01:8530'; TargetGroup = 'Servers' })
    }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'loads the shipped baseline' {
        $Baseline.Settings.Count | Should -BeGreaterThan 0
        $Baseline.Settings.Name | Should -Contain 'WUServer'
        $Baseline.Settings.Name | Should -Contain 'UseWUServer'
    }
    It 'finds the shipped baseline by default' {
        (Import-WsusManagerBaseline).Settings.Count | Should -Be $Baseline.Settings.Count
    }
    It 'rejects a setting with an unsupported type' {
        $bad = Join-Path $TestDrive 'bad.json'
        '{"Settings":[{"Path":"HKLM:\\SOFTWARE\\X","Name":"A","Type":"Binary","Value":1}]}' | Set-Content $bad
        { Import-WsusManagerBaseline -Path $bad } | Should -Throw '*Type must be*'
    }
    It 'rejects non-HKLM paths' {
        $bad = Join-Path $TestDrive 'hkcu.json'
        '{"Settings":[{"Path":"HKCU:\\Software\\X","Name":"A","Type":"DWord","Value":1}]}' | Set-Content $bad
        { Import-WsusManagerBaseline -Path $bad } | Should -Throw '*only HKLM*'
    }
    It 'replaces tokens without touching the original settings' {
        ($Resolved | Where-Object Name -eq 'WUServer').Value | Should -Be 'http://wsus01:8530'
        ($Resolved | Where-Object Name -eq 'TargetGroup').Value | Should -Be 'Servers'
        ($Baseline.Settings | Where-Object Name -eq 'WUServer').Value | Should -Be '{WsusServerUrl}'
    }
    It 'throws when a used token has no value' {
        { Resolve-WsusManagerBaseline -Settings $Baseline.Settings -Tokens @{} } | Should -Throw '*WsusServerUrl*'
    }
}

Describe 'Compare-WsusManagerRegistryValue' {
    BeforeAll {
        Import-Module $Manifest -Force
        $script:Dword = [pscustomobject]@{ Ensure = 'Present'; Type = 'DWord'; Value = 4; AllowedValues = $null }
        $script:Allowed = [pscustomobject]@{ Ensure = 'Present'; Type = 'DWord'; Value = 4; AllowedValues = @(3, 4) }
        $script:Text = [pscustomobject]@{ Ensure = 'Present'; Type = 'String'; Value = 'http://wsus01:8530'; AllowedValues = $null }
        $script:Absent = [pscustomobject]@{ Ensure = 'Absent'; Type = $null; Value = $null; AllowedValues = $null }
    }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'is Compliant on an exact DWORD match' {
        (Compare-WsusManagerRegistryValue -Setting $Dword -Exists $true -ActualValue 4 -ActualType 'DWord').Status | Should -Be 'Compliant'
    }
    It 'is NonCompliant on a different DWORD' {
        (Compare-WsusManagerRegistryValue -Setting $Dword -Exists $true -ActualValue 2 -ActualType 'DWord').Status | Should -Be 'NonCompliant'
    }
    It 'is Missing when the value does not exist' {
        (Compare-WsusManagerRegistryValue -Setting $Dword -Exists $false).Status | Should -Be 'Missing'
    }
    It 'accepts any of AllowedValues' {
        (Compare-WsusManagerRegistryValue -Setting $Allowed -Exists $true -ActualValue 3 -ActualType 'DWord').Status | Should -Be 'Compliant'
        (Compare-WsusManagerRegistryValue -Setting $Allowed -Exists $true -ActualValue 2 -ActualType 'DWord').Status | Should -Be 'NonCompliant'
    }
    It 'compares strings case-insensitively' {
        (Compare-WsusManagerRegistryValue -Setting $Text -Exists $true -ActualValue 'HTTP://WSUS01:8530' -ActualType 'String').Status | Should -Be 'Compliant'
    }
    It 'flags a wrong value type' {
        (Compare-WsusManagerRegistryValue -Setting $Text -Exists $true -ActualValue 'http://wsus01:8530' -ActualType 'ExpandString').Status | Should -Be 'NonCompliant'
    }
    It 'treats a negative Int32 read-back as the unsigned DWORD' {
        $big = [pscustomobject]@{ Ensure = 'Present'; Type = 'DWord'; Value = 4294967295; AllowedValues = $null }
        (Compare-WsusManagerRegistryValue -Setting $big -Exists $true -ActualValue -1 -ActualType 'DWord').Status | Should -Be 'Compliant'
    }
    It 'handles Ensure = Absent' {
        (Compare-WsusManagerRegistryValue -Setting $Absent -Exists $false).Status | Should -Be 'Compliant'
        (Compare-WsusManagerRegistryValue -Setting $Absent -Exists $true -ActualValue 1 -ActualType 'DWord').Status | Should -Be 'NonCompliant'
    }
}

Describe 'Get-WsusManagerComplianceSummary' {
    BeforeAll { Import-Module $Manifest -Force }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'rolls rows up per computer' {
        $rows = @(
            [pscustomobject]@{ ComputerName = 'a'; Setting = 'x'; Status = 'Compliant' }
            [pscustomobject]@{ ComputerName = 'a'; Setting = 'y'; Status = 'Missing' }
            [pscustomobject]@{ ComputerName = 'b'; Setting = 'x'; Status = 'Compliant' }
            [pscustomobject]@{ ComputerName = 'c'; Setting = 'x'; Status = 'Error' }
        )
        $summary = @($rows | Get-WsusManagerComplianceSummary)
        $summary.Count | Should -Be 3
        $a = $summary | Where-Object ComputerName -eq 'a'
        $a.Status | Should -Be 'NonCompliant'
        $a.CompliancePercent | Should -Be 50
        $a.FailedSettings | Should -Be 'y'
        ($summary | Where-Object ComputerName -eq 'b').Status | Should -Be 'Compliant'
        ($summary | Where-Object ComputerName -eq 'c').Status | Should -Be 'Unreachable'
    }
}

Describe 'Reboot report merge' {
    BeforeAll { Import-Module $Manifest -Force }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'flags a reboot reported by WSUS only' {
        InModuleScope WsusManager {
            $row = Merge-WsusManagerRebootRow -ComputerName 'srv1' -WsusStatus ([pscustomobject]@{ InstalledPendingReboot = 2; LastReportedTime = (Get-Date) })
            $row.RebootNeeded | Should -BeTrue
            $row.DetectedBy | Should -Be 'WSUS'
        }
    }
    It 'flags a reboot detected on the client and carries uptime' {
        InModuleScope WsusManager {
            $client = [pscustomobject]@{ Online = $true; RebootPending = $true; RebootReasons = 'CBS'; LastBootTime = (Get-Date).AddDays(-45); UptimeDays = 45; Uptime = '45d 0h 0m'; Error = $null }
            $row = Merge-WsusManagerRebootRow -ComputerName 'srv1' -WsusStatus ([pscustomobject]@{ InstalledPendingReboot = 0; LastReportedTime = $null }) -ClientStatus $client
            $row.RebootNeeded | Should -BeTrue
            $row.DetectedBy | Should -Be 'Client'
            $row.UptimeDays | Should -Be 45
        }
    }
    It 'reports no reboot when neither source needs one' {
        InModuleScope WsusManager {
            $client = [pscustomobject]@{ Online = $true; RebootPending = $false; RebootReasons = ''; LastBootTime = (Get-Date); UptimeDays = 1; Uptime = '1d 0h 0m'; Error = $null }
            (Merge-WsusManagerRebootRow -ComputerName 'srv1' -ClientStatus $client).RebootNeeded | Should -BeFalse
        }
    }
    It 'formats uptime as days/hours/minutes' {
        InModuleScope WsusManager {
            Format-WsusManagerUptime -TimeSpan (New-TimeSpan -Days 40 -Hours 5 -Minutes 7) | Should -Be '40d 5h 7m'
        }
    }
}

Describe 'Targets and remoting helper' {
    BeforeAll { Import-Module $Manifest -Force }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'merges names and list files, skipping comments, blanks and duplicates' {
        $list = Join-Path $TestDrive 'servers.txt'
        "# comment`nsrv1`n`nsrv2`nsrv1" | Set-Content $list
        Resolve-WsusManagerTarget -ComputerName 'srv3' -ComputerListPath $list | Should -Be @('srv3', 'srv1', 'srv2')
    }
    It 'throws when there are no targets' {
        { Resolve-WsusManagerTarget } | Should -Throw '*No target computers*'
    }
    It 'runs localhost in-process and wraps errors per computer' {
        InModuleScope WsusManager {
            $ok = Invoke-WsusManagerRemote -ComputerName 'localhost' -ScriptBlock { param($n) $n * 2 } -ArgumentList 21
            $ok.Success | Should -BeTrue
            $ok.Result[0] | Should -Be 42

            $bad = Invoke-WsusManagerRemote -ComputerName 'localhost' -ScriptBlock { throw 'boom' }
            $bad.Success | Should -BeFalse
            $bad.Error | Should -Be 'boom'
        }
    }
}

Describe 'Export-WsusManagerReport' {
    BeforeAll {
        Import-Module $Manifest -Force
        $script:Rows = @(
            [pscustomobject]@{ ComputerName = 'a'; Status = 'Compliant' }
            [pscustomobject]@{ ComputerName = 'b'; Status = 'Missing' }
        )
    }
    AfterAll { Remove-Module WsusManager -Force -ErrorAction SilentlyContinue }

    It 'writes CSV' {
        $p = Join-Path $TestDrive 'r.csv'
        Export-WsusManagerReport -InputObject $Rows -Path $p | Out-Null
        @(Import-Csv $p).Count | Should -Be 2
    }
    It 'writes JSON' {
        $p = Join-Path $TestDrive 'r.json'
        Export-WsusManagerReport -InputObject $Rows -Path $p | Out-Null
        @(Get-Content $p -Raw | ConvertFrom-Json).Count | Should -Be 2
    }
    It 'writes HTML with status highlighting' {
        $p = Join-Path $TestDrive 'r.html'
        Export-WsusManagerReport -InputObject $Rows -Path $p -Title 'Test' | Out-Null
        $html = Get-Content $p -Raw
        $html | Should -Match 'class="good">Compliant'
        $html | Should -Match 'class="bad">Missing'
    }
    It 'rejects unknown formats' {
        { Export-WsusManagerReport -InputObject $Rows -Path (Join-Path $TestDrive 'r.txt') } | Should -Throw '*Unsupported*'
    }
}

Describe 'Portable exe build (combined script)' {
    BeforeAll {
        $script:Dist = Join-Path $TestDrive 'dist'
        & (Join-Path $ModuleRoot 'Build-WsusManagerExe.ps1') -SkipCompile -OutputDirectory $Dist | Out-Null
        $script:Combined = Join-Path $Dist 'WsusManager.combined.ps1'
    }

    It 'produces a single script that parses' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Combined, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }
    It 'inlines the module instead of importing it' {
        $text = Get-Content $Combined -Raw
        $text | Should -Not -Match 'Import-Module \(Join-Path \$PSScriptRoot'
        $text | Should -Match 'function Show-WsusManagerMenu'
        $text | Should -Match 'EmbeddedBaselineJson = @'''
    }
    It 'runs headless and uses the embedded baseline when no file is next to it' {
        Remove-Item (Join-Path $Dist 'WsusClientBaseline.json') -ErrorAction SilentlyContinue
        $report = Join-Path $TestDrive 'baseline.json'
        $exe = (Get-Process -Id $PID).Path
        Push-Location $TestDrive
        try {
            & $exe -NoProfile -NonInteractive -File $Combined -Action ShowBaseline -ReportPath $report -LogDirectory (Join-Path $TestDrive 'logs') | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        finally {
            Pop-Location
        }
        @(Get-Content $report -Raw | ConvertFrom-Json).Name | Should -Contain 'WUServer'
        Test-Path (Join-Path $TestDrive 'logs') | Should -BeTrue
    }
}
