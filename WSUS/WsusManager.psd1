#
# Module manifest for module 'WsusManager'
#

@{

RootModule = 'WsusManager.psm1'

ModuleVersion = '1.0.0'

GUID = '5b0c7e3e-2f6a-4d8e-9a41-7c3f0e1d2b64'

Author = 'Ryan Cashier'

CompanyName = 'Unknown'

Copyright = '(c) 2026 Ryan Cashier. All rights reserved.'

Description = 'WSUS Manager - WSUS update-group reporting (update status, needed updates, reboot-needed and uptime reports) plus Windows Update client control: force check-in, force install, force reboot, apply and audit Windows Update policy registry settings.'

PowerShellVersion = '5.1'

FunctionsToExport = @(
        'Connect-WsusManagerServer'
        'Get-WsusManagerServerInfo'
        'Get-WsusManagerServerUrl'
        'Get-WsusManagerGroup'
        'Get-WsusManagerGroupComputer'
        'Resolve-WsusManagerTarget'
        'Get-WsusManagerUpdateStatus'
        'Get-WsusManagerNeededUpdate'
        'Get-WsusManagerClientStatus'
        'Get-WsusManagerUptimeReport'
        'Get-WsusManagerRebootReport'
        'Invoke-WsusManagerCheckIn'
        'Invoke-WsusManagerUpdateInstall'
        'Get-WsusManagerUpdateInstallResult'
        'Restart-WsusManagerComputer'
        'Import-WsusManagerBaseline'
        'Resolve-WsusManagerBaseline'
        'Compare-WsusManagerRegistryValue'
        'Test-WsusManagerRegistryCompliance'
        'Get-WsusManagerComplianceSummary'
        'Set-WsusManagerClientRegistry'
        'Export-WsusManagerReport'
        'Set-WsusManagerLogDirectory'
        'Test-WsusManagerLocalApi'
        'Get-WsusManagerDefaultBaselinePath'
        'Show-WsusManagerMenu'
    )

CmdletsToExport = @()

VariablesToExport = @()

AliasesToExport = @()

PrivateData = @{
    PSData = @{
        Tags = @('WSUS', 'WindowsUpdate', 'Patching', 'Compliance')
    }
}

}
