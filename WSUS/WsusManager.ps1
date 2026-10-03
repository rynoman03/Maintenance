<#
.SYNOPSIS
    WSUS Manager - WSUS update-group reporting and Windows Update client control.

.DESCRIPTION
    Runs locally on your admin workstation and connects to the WSUS server you
    specify. With no -Action it opens the interactive menu (and asks which WSUS
    server to use, defaulting to the last one). With -Action it runs one task
    headless, prints the result and optionally exports it with -ReportPath.

    If the WSUS console (UpdateServices API) is not installed locally, WSUS
    queries run on the WSUS server itself over WinRM, so nothing has to be
    installed on the workstation. Client actions (check-in, install, reboot,
    registry, uptime) always use WinRM to the target computers.

    This same file is compiled into the portable WsusManager.exe by
    Build-WsusManagerExe.ps1.

.EXAMPLE
    .\WsusManager.ps1
    Interactive menu.

.EXAMPLE
    .\WsusManager.ps1 -WsusServer wsus01 -Action RebootReport -GroupName Servers -ReportPath C:\Reports\reboot.html

.EXAMPLE
    .\WsusManager.ps1 -WsusServer wsus01 -Action ComplianceReport -GroupName Workstations -ReportPath C:\Reports\compliance.csv

.EXAMPLE
    WsusManager.exe -WsusServer wsus01 -Action Reboot -GroupName Servers -OnlyIfRebootPending -DelaySeconds 300

.NOTES
    Exit codes for -Action runs: 0 = OK, 1 = error, 2 = findings
    (non-compliant computers, reboots needed, uptime over threshold, or a
    failed client action) so the script can drive scheduled monitoring.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Alias('Server')]
    [string]$WsusServer,

    [int]$Port = 8530,

    [switch]$UseSsl,

    [ValidateSet('Auto', 'Local', 'Remote')]
    [string]$ConnectionMode = 'Auto',

    [ValidateSet('Menu', 'ServerInfo', 'Groups', 'GroupComputers', 'UpdateStatus', 'NeededUpdates',
        'RebootReport', 'UptimeReport', 'ClientStatus', 'CheckIn', 'InstallUpdates', 'InstallResult',
        'Reboot', 'ShowBaseline', 'SetRegistry', 'ComplianceReport', 'ComplianceSummary')]
    [string]$Action = 'Menu',

    [string]$GroupName,

    [string[]]$ComputerName,

    [string]$ComputerListPath,

    [switch]$IncludeSubgroups,

    [string]$BaselinePath,

    [string]$WsusServerUrl,

    [string]$TargetGroup,

    [ValidateSet('AnyExceptDeclined', 'Approved', 'Any')]
    [string]$UpdateApproval = 'AnyExceptDeclined',

    [int]$UptimeThresholdDays = 30,

    [switch]$OnlyIfRebootPending,

    [ValidateRange(0, 600)]
    [int]$DelaySeconds = 0,

    [switch]$RebootIfRequired,

    [switch]$ResetAuthorization,

    [switch]$WaitForScan,

    [switch]$RestartUpdateService,

    [string]$ReportPath,

    [string]$LogDirectory,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$PromptForCredential
)

$ErrorActionPreference = 'Stop'

# Capture -WhatIf for the action itself, then clear it so it does not leak into
# logging and report export (in the exe the module code shares this scope).
$runWhatIf = [bool]$WhatIfPreference
$WhatIfPreference = $false

# <WSUSMANAGER-MODULE>
# Build-WsusManagerExe.ps1 replaces this block with the module source so the
# compiled exe is a single self-contained file.
Import-Module (Join-Path $PSScriptRoot 'WsusManager.psd1') -Force
# </WSUSMANAGER-MODULE>

try {
    if ($LogDirectory) {
        Set-WsusManagerLogDirectory -Path $LogDirectory -Confirm:$false
    }
    if ($PromptForCredential -and -not $Credential) {
        $Credential = Get-Credential -Message 'Account for WinRM to the WSUS server and client computers'
    }
    $cred = @{}
    if ($Credential) { $cred['Credential'] = $Credential }

    # Forward -WhatIf / -Confirm explicitly: preference variables do not flow
    # from a script into module functions.
    $act = @{}
    if ($runWhatIf) { $act['WhatIf'] = $true }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $act['Confirm'] = [bool]$PSBoundParameters['Confirm'] }

    if ($WsusServer) {
        $connectParams = @{ ServerName = $WsusServer; Port = $Port; UseSsl = $UseSsl; Mode = $ConnectionMode }
        $info = Connect-WsusManagerServer @connectParams @cred
        if ($Action -eq 'Menu') {
            $info | Format-List | Out-Host
        }
    }

    if ($Action -eq 'Menu') {
        Show-WsusManagerMenu -BaselinePath $BaselinePath @cred
        exit 0
    }

    $target = @{}
    if ($ComputerName) { $target['ComputerName'] = $ComputerName }
    if ($GroupName) { $target['GroupName'] = $GroupName }
    if ($ComputerListPath) { $target['ComputerListPath'] = $ComputerListPath }
    if ($IncludeSubgroups) { $target['IncludeSubgroups'] = $true }

    $registryParams = @{}
    if ($BaselinePath) { $registryParams['BaselinePath'] = $BaselinePath }
    if ($WsusServerUrl) { $registryParams['WsusServerUrl'] = $WsusServerUrl }
    if ($TargetGroup) { $registryParams['TargetGroup'] = $TargetGroup }

    $findings = $false
    $title = "WSUS Manager - $Action"

    switch ($Action) {
        'ServerInfo' { $result = Get-WsusManagerServerInfo }
        'Groups' { $result = Get-WsusManagerGroup }
        'GroupComputers' {
            if (-not $GroupName) { throw '-GroupName is required for GroupComputers.' }
            $result = Get-WsusManagerGroupComputer -GroupName $GroupName -IncludeSubgroups:$IncludeSubgroups
        }
        'UpdateStatus' {
            if ($GroupName -and -not $ComputerName) {
                $result = Get-WsusManagerUpdateStatus -GroupName $GroupName -IncludeSubgroups:$IncludeSubgroups -UpdateApproval $UpdateApproval
            }
            else {
                $result = Get-WsusManagerUpdateStatus -ComputerName (Resolve-WsusManagerTarget @target) -UpdateApproval $UpdateApproval
            }
        }
        'NeededUpdates' {
            if ($GroupName) {
                $result = Get-WsusManagerNeededUpdate -GroupName $GroupName -IncludeSubgroups:$IncludeSubgroups -UpdateApproval $UpdateApproval
            }
            elseif ($ComputerName) {
                $result = foreach ($c in $ComputerName) { Get-WsusManagerNeededUpdate -ComputerName $c -UpdateApproval $UpdateApproval }
            }
            else {
                throw '-GroupName or -ComputerName is required for NeededUpdates.'
            }
        }
        'RebootReport' {
            $result = Get-WsusManagerRebootReport @target @cred
            $findings = @($result | Where-Object { $_.RebootNeeded }).Count -gt 0
        }
        'UptimeReport' {
            $result = Get-WsusManagerUptimeReport -ComputerName (Resolve-WsusManagerTarget @target) -ThresholdDays $UptimeThresholdDays @cred
            $findings = @($result | Where-Object { $_.ExceedsThreshold }).Count -gt 0
        }
        'ClientStatus' {
            $result = Get-WsusManagerClientStatus -ComputerName (Resolve-WsusManagerTarget @target) @cred
        }
        'CheckIn' {
            $result = Invoke-WsusManagerCheckIn -ComputerName (Resolve-WsusManagerTarget @target) -ResetAuthorization:$ResetAuthorization -WaitForScan:$WaitForScan @act @cred
            $findings = @($result | Where-Object { -not $_.Success }).Count -gt 0
        }
        'InstallUpdates' {
            $result = Invoke-WsusManagerUpdateInstall -ComputerName (Resolve-WsusManagerTarget @target) -RebootIfRequired:$RebootIfRequired @act @cred
            $findings = @($result | Where-Object { -not $_.Started }).Count -gt 0
        }
        'InstallResult' {
            $result = Get-WsusManagerUpdateInstallResult -ComputerName (Resolve-WsusManagerTarget @target) @cred
            $findings = @($result | Where-Object { $_.Failed -gt 0 -or $_.Status -eq 'Error' -or -not $_.Reachable }).Count -gt 0
        }
        'Reboot' {
            $result = Restart-WsusManagerComputer -ComputerName (Resolve-WsusManagerTarget @target) -OnlyIfRebootPending:$OnlyIfRebootPending -DelaySeconds $DelaySeconds @act @cred
            $findings = @($result | Where-Object { $_.Error }).Count -gt 0
        }
        'ShowBaseline' {
            $result = (Import-WsusManagerBaseline -Path $BaselinePath).Settings
        }
        'SetRegistry' {
            $result = Set-WsusManagerClientRegistry @target @registryParams -RestartUpdateService:$RestartUpdateService -CheckIn:$RestartUpdateService @act @cred
            $findings = @($result | Where-Object { $_.Status -in 'Error', 'Unreachable' }).Count -gt 0
        }
        'ComplianceReport' {
            $result = Test-WsusManagerRegistryCompliance @target @registryParams @cred
            $findings = @($result | Where-Object { $_.Status -ne 'Compliant' }).Count -gt 0
        }
        'ComplianceSummary' {
            $result = Test-WsusManagerRegistryCompliance @target @registryParams @cred | Get-WsusManagerComplianceSummary
            $findings = @($result | Where-Object { $_.Status -ne 'Compliant' }).Count -gt 0
        }
    }

    $result = @($result)
    $result | Format-Table -AutoSize -Wrap | Out-Host
    if ($ReportPath) {
        $file = Export-WsusManagerReport -InputObject $result -Path $ReportPath -Title $title
        Write-Host "Report saved to $($file.FullName)"
    }

    if ($findings) { exit 2 }
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
