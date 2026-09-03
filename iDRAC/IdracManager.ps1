<#
.SYNOPSIS
    Windows-native Dell iDRAC Redfish manager.

.DESCRIPTION
    Provides an interactive menu and optional command-line actions for common
    Dell iDRAC maintenance checks from Windows PowerShell or PowerShell 7+.
    The script uses Redfish over HTTPS and prompts for credentials when needed.

.NOTES
    Run from a trusted administration workstation. Use -SkipCertificateCheck
    only for lab systems or known self-signed iDRAC certificates.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$HostName,

    [string]$Username,

    [string]$Password,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$LogPath,

    [switch]$SkipCertificateCheck,

    [ValidateSet('SystemDefault', 'Tls12', 'Tls11', 'Tls10', 'Legacy')]
    [string]$TlsProtocol = 'Tls12',

    [switch]$GetHealth,

    [switch]$GetPowerState,

    [switch]$GetFirmwareInventory,

    [switch]$GetThermalSensors,

    [switch]$GetUsers,

    [switch]$SecurityAudit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Add-IdracSecurityProtocol {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.SecurityProtocolType]$CurrentProtocol,

        [Parameter(Mandatory = $true)]
        [int]$ProtocolValue
    )

    $protocol = [System.Net.SecurityProtocolType]$ProtocolValue
    $CurrentProtocol -bor $protocol
}

function Set-IdracSecurityProtocol {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SystemDefault', 'Tls12', 'Tls11', 'Tls10', 'Legacy')]
        [string]$Protocol
    )

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return
    }

    $selectedProtocol = [System.Net.SecurityProtocolType]0

    switch ($Protocol) {
        'SystemDefault' {
            $selectedProtocol = [System.Net.SecurityProtocolType]0
        }
        'Tls12' {
            $selectedProtocol = Add-IdracSecurityProtocol -CurrentProtocol $selectedProtocol -ProtocolValue 3072
        }
        'Tls11' {
            $selectedProtocol = Add-IdracSecurityProtocol -CurrentProtocol $selectedProtocol -ProtocolValue 768
        }
        'Tls10' {
            $selectedProtocol = Add-IdracSecurityProtocol -CurrentProtocol $selectedProtocol -ProtocolValue 192
        }
        'Legacy' {
            $selectedProtocol = Add-IdracSecurityProtocol -CurrentProtocol $selectedProtocol -ProtocolValue 3072
            $selectedProtocol = Add-IdracSecurityProtocol -CurrentProtocol $selectedProtocol -ProtocolValue 768
            $selectedProtocol = Add-IdracSecurityProtocol -CurrentProtocol $selectedProtocol -ProtocolValue 192
        }
    }

    [System.Net.ServicePointManager]::SecurityProtocol = $selectedProtocol
}

function Initialize-IdracCertificatePolicy {
    param(
        [switch]$EnableSkip
    )

    if (-not $EnableSkip) {
        return
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

function New-IdracSessionContext {
    param(
        [string]$ComputerName,
        [string]$UserName,
        [string]$PlainTextPassword,
        [System.Management.Automation.PSCredential]$InputCredential,
        [string]$InputLogPath,
        [switch]$AllowUntrustedCertificate,
        [ValidateSet('SystemDefault', 'Tls12', 'Tls11', 'Tls10', 'Legacy')]
        [string]$InputTlsProtocol = 'Tls12'
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        $ComputerName = Read-Host 'Enter iDRAC host name or IP address'
    }

    if (-not $InputCredential) {
        if (-not [string]::IsNullOrWhiteSpace($UserName) -and -not [string]::IsNullOrWhiteSpace($PlainTextPassword)) {
            $securePassword = ConvertTo-SecureString -String $PlainTextPassword -AsPlainText -Force
            $InputCredential = New-Object System.Management.Automation.PSCredential($UserName, $securePassword)
        }
        else {
            if ([string]::IsNullOrWhiteSpace($UserName)) {
                $InputCredential = Get-Credential -Message "Enter credentials for iDRAC $ComputerName"
            }
            else {
                $InputCredential = Get-Credential -UserName $UserName -Message "Enter password for iDRAC $ComputerName"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($InputLogPath)) {
        $safeHostName = $ComputerName -replace '[^a-zA-Z0-9._-]', '_'
        $InputLogPath = Join-Path -Path $PSScriptRoot -ChildPath ("idrac_manager_{0}_{1}.log" -f $safeHostName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    Set-IdracSecurityProtocol -Protocol $InputTlsProtocol
    Initialize-IdracCertificatePolicy -EnableSkip:$AllowUntrustedCertificate

    [pscustomobject]@{
        HostName = $ComputerName
        BaseUri = "https://$ComputerName"
        Credential = $InputCredential
        LogPath = $InputLogPath
        SkipCertificateCheck = [bool]$AllowUntrustedCertificate
        TlsProtocol = $InputTlsProtocol
    }
}

function Write-IdracLog {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $Context.LogPath -Value $entry
}

function Invoke-IdracRedfishRequest {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [object]$Body
    )

    $uri = if ($Path -match '^https?://') { $Path } else { '{0}{1}' -f $Context.BaseUri, $Path }
    Write-IdracLog -Context $Context -Message "$Method $uri"

    $credentialBytes = [System.Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $Context.Credential.UserName, $Context.Credential.GetNetworkCredential().Password))
    $request = @{
        Uri = $uri
        Method = $Method
        Headers = @{
            Accept = 'application/json'
            Authorization = 'Basic {0}' -f [Convert]::ToBase64String($credentialBytes)
        }
        ErrorAction = 'Stop'
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $request.UseBasicParsing = $true
    }

    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    if ($Context.SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 6) {
        $request.SkipCertificateCheck = $true
    }

    try {
        Invoke-RestMethod @request
    }
    catch {
        $message = 'Redfish request failed: {0} {1}. TLS mode: {2}. {3}' -f $Method, $uri, $Context.TlsProtocol, $_.Exception.Message
        Write-IdracLog -Context $Context -Message $message -Level ERROR
        throw $message
    }
}

function Show-IdracObjectTable {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Data
    )

    $Data | Format-List | Out-Host
}

function Get-IdracSystemSummary {
    param([Parameter(Mandatory = $true)][object]$Context)

    Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/Systems/System.Embedded.1'
}

function Get-IdracPowerStateInfo {
    param([Parameter(Mandatory = $true)][object]$Context)

    $system = Get-IdracSystemSummary -Context $Context
    [pscustomobject]@{
        HostName = $Context.HostName
        System = $system.Name
        Model = $system.Model
        SerialNumber = $system.SerialNumber
        PowerState = $system.PowerState
        Health = $system.Status.Health
        State = $system.Status.State
    }
}

function Get-IdracSystemHealthInfo {
    param([Parameter(Mandatory = $true)][object]$Context)

    $system = Get-IdracSystemSummary -Context $Context
    $manager = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/Managers/iDRAC.Embedded.1'
    $chassis = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/Chassis/System.Embedded.1'

    [pscustomobject]@{
        HostName = $Context.HostName
        SystemHealth = $system.Status.Health
        SystemState = $system.Status.State
        PowerState = $system.PowerState
        ManagerHealth = $manager.Status.Health
        ManagerState = $manager.Status.State
        ChassisHealth = $chassis.Status.Health
        ChassisState = $chassis.Status.State
    }
}

function Get-IdracFirmwareInventoryInfo {
    param([Parameter(Mandatory = $true)][object]$Context)

    $inventory = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/UpdateService/FirmwareInventory'
    foreach ($member in $inventory.Members) {
        $item = Invoke-IdracRedfishRequest -Context $Context -Path $member.'@odata.id'
        [pscustomobject]@{
            Name = $item.Name
            Id = $item.Id
            Version = $item.Version
            Status = $item.Status.Health
            State = $item.Status.State
        }
    }
}

function Get-IdracThermalSensorInfo {
    param([Parameter(Mandatory = $true)][object]$Context)

    $thermal = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/Chassis/System.Embedded.1/Thermal'

    foreach ($temperature in $thermal.Temperatures) {
        [pscustomobject]@{
            Type = 'Temperature'
            Name = $temperature.Name
            Reading = $temperature.ReadingCelsius
            Units = 'Celsius'
            Health = $temperature.Status.Health
            State = $temperature.Status.State
        }
    }

    foreach ($fan in $thermal.Fans) {
        [pscustomobject]@{
            Type = 'Fan'
            Name = $fan.Name
            Reading = $fan.Reading
            Units = $fan.ReadingUnits
            Health = $fan.Status.Health
            State = $fan.Status.State
        }
    }
}

function Get-IdracUserInfo {
    param([Parameter(Mandatory = $true)][object]$Context)

    $accounts = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/AccountService/Accounts'
    foreach ($member in $accounts.Members) {
        $account = Invoke-IdracRedfishRequest -Context $Context -Path $member.'@odata.id'
        [pscustomobject]@{
            Id = $account.Id
            UserName = $account.UserName
            Enabled = $account.Enabled
            RoleId = $account.RoleId
            Locked = $account.Locked
        }
    }
}

function Invoke-IdracSecurityAudit {
    param([Parameter(Mandatory = $true)][object]$Context)

    $manager = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/Managers/iDRAC.Embedded.1'
    $accountService = Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/AccountService'
    $users = @(Get-IdracUserInfo -Context $Context)

    $findings = New-Object System.Collections.Generic.List[object]

    $defaultAccounts = $users | Where-Object { $_.Enabled -eq $true -and $_.UserName -match '^(root|calvin|admin|administrator)$' }
    foreach ($account in $defaultAccounts) {
        $findings.Add([pscustomobject]@{
            Severity = 'Review'
            Area = 'Accounts'
            Finding = "Enabled default or commonly targeted account: $($account.UserName)"
        })
    }

    if ($accountService.AccountLockoutThreshold -eq 0 -or $null -eq $accountService.AccountLockoutThreshold) {
        $findings.Add([pscustomobject]@{
            Severity = 'Review'
            Area = 'AccountService'
            Finding = 'Account lockout threshold is missing or disabled.'
        })
    }

    if ($manager.DateTimeLocalOffset -and $manager.DateTime) {
        $findings.Add([pscustomobject]@{
            Severity = 'Info'
            Area = 'Manager'
            Finding = "Manager reports time $($manager.DateTime) with offset $($manager.DateTimeLocalOffset)."
        })
    }

    if ($findings.Count -eq 0) {
        $findings.Add([pscustomobject]@{
            Severity = 'Info'
            Area = 'Security'
            Finding = 'No basic account or lockout findings were detected by this script.'
        })
    }

    $findings
}

function Invoke-IdracPowerAction {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('On', 'ForceOff', 'GracefulShutdown', 'GracefulRestart', 'ForceRestart', 'Nmi', 'PushPowerButton')]
        [string]$ResetType
    )

    $target = "$($Context.HostName) power action $ResetType"
    if ($PSCmdlet.ShouldProcess($target, 'Submit Redfish ComputerSystem.Reset action')) {
        Invoke-IdracRedfishRequest -Context $Context -Path '/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset' -Method POST -Body @{ ResetType = $ResetType }
    }
}

function Show-IdracMainMenu {
    param([Parameter(Mandatory = $true)][object]$Context)

    do {
        Write-Host ''
        Write-Host 'Dell iDRAC Manager' -ForegroundColor Cyan
        Write-Host "Target: $($Context.HostName)"
        Write-Host '1. Show power state'
        Write-Host '2. Show system health'
        Write-Host '3. Show firmware inventory'
        Write-Host '4. Show thermal and fan sensors'
        Write-Host '5. Show iDRAC users'
        Write-Host '6. Run basic security audit'
        Write-Host '7. Submit power action'
        Write-Host 'Q. Quit'
        $choice = Read-Host 'Select an option'

        switch ($choice.ToUpperInvariant()) {
            '1' { Get-IdracPowerStateInfo -Context $Context | Format-List | Out-Host }
            '2' { Get-IdracSystemHealthInfo -Context $Context | Format-List | Out-Host }
            '3' { Get-IdracFirmwareInventoryInfo -Context $Context | Format-Table -AutoSize | Out-Host }
            '4' { Get-IdracThermalSensorInfo -Context $Context | Format-Table -AutoSize | Out-Host }
            '5' { Get-IdracUserInfo -Context $Context | Format-Table -AutoSize | Out-Host }
            '6' { Invoke-IdracSecurityAudit -Context $Context | Format-Table -AutoSize | Out-Host }
            '7' {
                Write-Host 'Supported actions: On, ForceOff, GracefulShutdown, GracefulRestart, ForceRestart, Nmi, PushPowerButton'
                $action = Read-Host 'Enter power action'
                if ($action -in @('On', 'ForceOff', 'GracefulShutdown', 'GracefulRestart', 'ForceRestart', 'Nmi', 'PushPowerButton')) {
                    Invoke-IdracPowerAction -Context $Context -ResetType $action -Confirm
                }
                else {
                    Write-Warning 'Invalid power action.'
                }
            }
            'Q' { return }
            default { Write-Warning 'Invalid menu option.' }
        }
    } while ($true)
}

$context = New-IdracSessionContext -ComputerName $HostName -UserName $Username -PlainTextPassword $Password -InputCredential $Credential -InputLogPath $LogPath -AllowUntrustedCertificate:$SkipCertificateCheck -InputTlsProtocol $TlsProtocol
Write-IdracLog -Context $context -Message "Started iDRAC Manager for $($context.HostName) using TLS mode $($context.TlsProtocol)"

$actionRequested = $GetHealth -or $GetPowerState -or $GetFirmwareInventory -or $GetThermalSensors -or $GetUsers -or $SecurityAudit

if ($GetPowerState) {
    Get-IdracPowerStateInfo -Context $context | Format-List | Out-Host
}

if ($GetHealth) {
    Get-IdracSystemHealthInfo -Context $context | Format-List | Out-Host
}

if ($GetFirmwareInventory) {
    Get-IdracFirmwareInventoryInfo -Context $context | Format-Table -AutoSize | Out-Host
}

if ($GetThermalSensors) {
    Get-IdracThermalSensorInfo -Context $context | Format-Table -AutoSize | Out-Host
}

if ($GetUsers) {
    Get-IdracUserInfo -Context $context | Format-Table -AutoSize | Out-Host
}

if ($SecurityAudit) {
    Invoke-IdracSecurityAudit -Context $context | Format-Table -AutoSize | Out-Host
}

if (-not $actionRequested) {
    Show-IdracMainMenu -Context $context
}

Write-IdracLog -Context $context -Message 'Finished iDRAC Manager run'
Write-Host "Log written to: $($context.LogPath)"
