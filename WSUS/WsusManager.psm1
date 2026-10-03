#
# WsusManager - WSUS update-group reporting and Windows Update client control.
#
# Server side (needs the UpdateServices / WSUS administration API on the machine
# running this module):
#   * connect to a WSUS server, list computer target groups,
#   * per-computer update status and per-update "needed" lists,
#   * reboot-needed reporting (WSUS "installed, pending reboot" counts).
#
# Client side (PowerShell remoting / WinRM to each target computer):
#   * live reboot-pending and system uptime report,
#   * force a Windows Update check-in / detection + status report,
#   * force update download + install (scheduled task as SYSTEM),
#   * force reboot,
#   * apply a Windows Update policy registry baseline (JSON) and check
#     registry compliance against that same baseline.
#
# Every state-changing function supports -WhatIf / -Confirm.
#

Set-StrictMode -Version 2.0

# --------------------------------------------------------------------------
# Module state
# --------------------------------------------------------------------------

$script:WsusConnection = $null
$script:LastResult = $null
$script:WsusManagerLogDir = $null

$script:BaselineFileName = 'WsusClientBaseline.json'
# Filled in by Build-WsusManagerExe.ps1 so the portable .exe carries a default
# baseline even when no WsusClientBaseline.json sits next to it.
if (-not (Test-Path -Path 'variable:script:EmbeddedBaselineJson')) {
    $script:EmbeddedBaselineJson = $null
}
$script:ClientWorkFolder = 'C:\ProgramData\WsusManager'
$script:InstallTaskName = 'WsusManager-InstallUpdates'
$script:SupportedValueTypes = @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString')

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------

function Get-WsusManagerLogDirectory {
    [CmdletBinding()]
    param()

    if ($script:WsusManagerLogDir) {
        return $script:WsusManagerLogDir
    }

    $base = $env:ProgramData
    if (-not $base) {
        $base = [System.IO.Path]::GetTempPath()
    }
    Join-Path (Join-Path $base 'WsusManager') 'Logs'
}

function Set-WsusManagerLogDirectory {
    <#
    .SYNOPSIS
        Sets the folder used for the WsusManager log file and registry backups.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Use as WsusManager log directory')) {
        $script:WsusManagerLogDir = $Path
    }
}

function Write-WsusManagerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line

    try {
        $dir = Get-WsusManagerLogDirectory
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
        }
        $file = Join-Path $dir ('WsusManager-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -WhatIf:$false -ErrorAction Stop
    }
    catch {
        # Logging is best effort; never let a log failure abort an operation.
        Write-Verbose "Could not write log file: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
# Remoting helpers
# --------------------------------------------------------------------------

function Test-WsusManagerLocalComputer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    $name = $ComputerName.Trim()
    if ($name -in @('localhost', '.', '127.0.0.1', '::1')) {
        return $true
    }
    if (-not $env:COMPUTERNAME) {
        return $false
    }
    ($name -eq $env:COMPUTERNAME) -or ($name -like "$($env:COMPUTERNAME).*")
}

function Invoke-WsusManagerRemote {
    <#
    .SYNOPSIS
        Runs a script block on each computer and returns one row per computer:
        ComputerName, Success, Result (array), Error.

    .DESCRIPTION
        The local computer is run in-process (no WinRM needed); everything else
        fans out through a single Invoke-Command call so WinRM parallelises it.
        Unreachable computers come back as Success = $false rather than errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [System.Management.Automation.PSCredential]$Credential,

        [int]$ThrottleLimit = 32
    )

    $names = @($ComputerName | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $rows = @{}
    $remote = New-Object System.Collections.Generic.List[string]

    foreach ($name in $names) {
        if (Test-WsusManagerLocalComputer -ComputerName $name) {
            try {
                $output = & $ScriptBlock @ArgumentList
                $rows[$name] = [pscustomobject]@{ ComputerName = $name; Success = $true; Result = @($output); Error = $null }
            }
            catch {
                $rows[$name] = [pscustomobject]@{ ComputerName = $name; Success = $false; Result = @(); Error = $_.Exception.Message }
            }
        }
        else {
            $remote.Add($name)
        }
    }

    if ($remote.Count -gt 0) {
        $remoteErrors = $null
        $invokeParams = @{
            ComputerName  = $remote.ToArray()
            ScriptBlock   = $ScriptBlock
            ArgumentList  = $ArgumentList
            ThrottleLimit = $ThrottleLimit
            ErrorAction   = 'SilentlyContinue'
            ErrorVariable = 'remoteErrors'
        }
        if ($Credential) {
            $invokeParams['Credential'] = $Credential
        }

        $output = @(Invoke-Command @invokeParams)

        foreach ($group in ($output | Group-Object -Property PSComputerName)) {
            $rows[$group.Name] = [pscustomobject]@{ ComputerName = $group.Name; Success = $true; Result = @($group.Group); Error = $null }
        }

        foreach ($err in @($remoteErrors)) {
            $target = $null
            if ($err.PSObject.Properties['OriginInfo'] -and $err.OriginInfo) {
                $target = $err.OriginInfo.PSComputerName
            }
            if (-not $target -and $err.TargetObject -is [string]) {
                $target = $err.TargetObject
            }
            if (-not $target) {
                continue
            }

            $message = $err.Exception.Message
            if ($rows.ContainsKey($target)) {
                $rows[$target].Success = $false
                $rows[$target].Error = (@($rows[$target].Error, $message) | Where-Object { $_ }) -join '; '
            }
            else {
                $rows[$target] = [pscustomobject]@{ ComputerName = $target; Success = $false; Result = @(); Error = $message }
            }
        }
    }

    foreach ($name in $names) {
        if ($rows.ContainsKey($name)) {
            $row = $rows[$name]
            $row.ComputerName = $name
            $row
        }
        else {
            [pscustomobject]@{ ComputerName = $name; Success = $false; Result = @(); Error = 'No response from computer.' }
        }
    }
}

function Format-WsusManagerUptime {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [timespan]$TimeSpan
    )

    '{0}d {1}h {2}m' -f [int][math]::Floor($TimeSpan.TotalDays), $TimeSpan.Hours, $TimeSpan.Minutes
}

# --------------------------------------------------------------------------
# Remote script blocks (run ON the target computer - no module functions
# are available there, so each block is self-contained).
# --------------------------------------------------------------------------

$script:ClientStatusScript = {
    $ErrorActionPreference = 'Stop'
    $reasons = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    $lastBoot = $null
    $osCaption = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $lastBoot = $os.LastBootUpTime
        $osCaption = $os.Caption
    }
    catch {
        $errors.Add("Uptime: $($_.Exception.Message)")
    }

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('WindowsUpdate')
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('ComponentBasedServicing')
    }
    try {
        $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sm -and $sm.PendingFileRenameOperations) {
            $reasons.Add('PendingFileRename')
        }
    }
    catch { }
    try {
        $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
        $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
        if ($active -ne $pending) {
            $reasons.Add('ComputerRename')
        }
    }
    catch { }
    try {
        $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction Stop
        if ($ccm -and ($ccm.RebootPending -or $ccm.IsHardRebootPending)) {
            $reasons.Add('ConfigMgr')
        }
    }
    catch { }

    $lastSearch = $null
    $lastInstall = $null
    try {
        $au = New-Object -ComObject Microsoft.Update.AutoUpdate
        $lastSearch = $au.Results.LastSearchSuccessDate
        $lastInstall = $au.Results.LastInstallationSuccessDate
    }
    catch {
        $errors.Add("WUA: $($_.Exception.Message)")
    }
    try {
        if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired -and -not $reasons.Contains('WindowsUpdate')) {
            $reasons.Add('WindowsUpdate')
        }
    }
    catch { }

    $serviceStatus = $null
    try {
        $serviceStatus = [string](Get-Service -Name wuauserv).Status
    }
    catch { }

    $wuServer = $null
    try {
        $policy = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
        if ($policy -and $policy.PSObject.Properties['WUServer']) {
            $wuServer = $policy.WUServer
        }
    }
    catch { }

    [pscustomobject]@{
        LastBootTime           = $lastBoot
        Now                    = Get-Date
        OperatingSystem        = $osCaption
        RebootPending          = ($reasons.Count -gt 0)
        RebootReasons          = ($reasons -join '; ')
        LastSearchSuccess      = $lastSearch
        LastInstallSuccess     = $lastInstall
        UpdateServiceStatus    = $serviceStatus
        ConfiguredWsusServer   = $wuServer
        Errors                 = ($errors -join '; ')
    }
}

$script:CheckInScript = {
    param([bool]$ResetAuthorization, [bool]$WaitForScan)

    $ErrorActionPreference = 'Stop'
    $actions = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $applicable = $null

    $wuauclt = Join-Path $env:SystemRoot 'System32\wuauclt.exe'
    $usoclient = Join-Path $env:SystemRoot 'System32\UsoClient.exe'

    try {
        $svc = Get-Service -Name wuauserv
        if ($svc.Status -ne 'Running') {
            Start-Service -Name wuauserv
            $actions.Add('Started wuauserv')
        }
    }
    catch { $errors.Add("wuauserv: $($_.Exception.Message)") }

    if ($ResetAuthorization -and (Test-Path $wuauclt)) {
        try {
            & $wuauclt /resetauthorization /detectnow | Out-Null
            $actions.Add('wuauclt /resetauthorization /detectnow')
        }
        catch { $errors.Add("resetauthorization: $($_.Exception.Message)") }
    }

    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
        $actions.Add('AutoUpdate.DetectNow()')
    }
    catch { $errors.Add("DetectNow: $($_.Exception.Message)") }

    if ($WaitForScan) {
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $session.ClientApplicationID = 'WsusManager'
            $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
            $applicable = $result.Updates.Count
            $actions.Add('Synchronous WUA scan')
        }
        catch { $errors.Add("Scan: $($_.Exception.Message)") }
    }

    if (Test-Path $usoclient) {
        try {
            & $usoclient StartScan | Out-Null
            $actions.Add('UsoClient StartScan')
        }
        catch { $errors.Add("UsoClient: $($_.Exception.Message)") }
    }

    if (Test-Path $wuauclt) {
        try {
            & $wuauclt /reportnow | Out-Null
            $actions.Add('wuauclt /reportnow')
        }
        catch { $errors.Add("reportnow: $($_.Exception.Message)") }
    }

    [pscustomobject]@{
        Actions           = ($actions -join '; ')
        ApplicableUpdates = $applicable
        Errors            = ($errors -join '; ')
    }
}

# Runs on the target as SYSTEM through a scheduled task. The WUA download and
# install APIs refuse to run from a remote (WinRM) logon, hence the task.
$script:InstallUpdatesClientScript = @'
param(
    [string]$Criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'",
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $work 'InstallUpdates.log'
$resultFile = Join-Path $work 'InstallUpdates.result.json'

function Write-Log([string]$Message) {
    Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

$result = [ordered]@{
    StartTime      = (Get-Date).ToString('o')
    EndTime        = $null
    Status         = 'Running'
    Criteria       = $Criteria
    Found          = 0
    Downloaded     = 0
    Installed      = 0
    Failed         = 0
    RebootRequired = $false
    RebootStarted  = $false
    Updates        = @()
    Error          = $null
}
$result | ConvertTo-Json -Depth 4 | Set-Content -Path $resultFile

try {
    Write-Log "Searching: $Criteria"
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'WsusManager'
    $search = $session.CreateUpdateSearcher().Search($Criteria)
    $result.Found = $search.Updates.Count
    Write-Log "Found $($result.Found) update(s)."

    if ($result.Found -eq 0) {
        $result.Status = 'NoUpdates'
    }
    else {
        $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $search.Updates) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$toDownload.Add($u)
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toDownload
        Write-Log 'Downloading...'
        [void]$downloader.Download()

        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $search.Updates) {
            if ($u.IsDownloaded) { [void]$toInstall.Add($u) }
        }
        $result.Downloaded = $toInstall.Count
        Write-Log "Downloaded $($result.Downloaded) update(s). Installing..."

        if ($toInstall.Count -gt 0) {
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $toInstall
            $install = $installer.Install()
            $codes = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
            $list = @()
            for ($i = 0; $i -lt $toInstall.Count; $i++) {
                $code = $install.GetUpdateResult($i).ResultCode
                $kb = ($toInstall.Item($i).KBArticleIDs | ForEach-Object { "KB$_" }) -join ','
                $list += [ordered]@{ Title = $toInstall.Item($i).Title; KB = $kb; Result = $codes[[int]$code] }
                if ($code -in 2, 3) { $result.Installed++ } else { $result.Failed++ }
                Write-Log ("{0} -> {1}" -f $toInstall.Item($i).Title, $codes[[int]$code])
            }
            $result.Updates = $list
            $result.RebootRequired = [bool]$install.RebootRequired
        }
        $result.Status = 'Completed'
    }
}
catch {
    $result.Status = 'Error'
    $result.Error = $_.Exception.Message
    Write-Log "ERROR: $($_.Exception.Message)"
}

$result.EndTime = (Get-Date).ToString('o')
$result | ConvertTo-Json -Depth 4 | Set-Content -Path $resultFile

if ($Reboot -and $result.RebootRequired) {
    Write-Log 'Reboot required - restarting in 60 seconds.'
    $result.RebootStarted = $true
    $result | ConvertTo-Json -Depth 4 | Set-Content -Path $resultFile
    & shutdown.exe /r /t 60 /c 'Restart to finish installing Windows updates (WsusManager).' /d p:2:17
}
'@

$script:StartInstallScript = {
    param([string]$WorkFolder, [string]$TaskName, [string]$ScriptText, [string]$Criteria, [bool]$Reboot)

    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path $WorkFolder)) {
        New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    }
    $scriptPath = Join-Path $WorkFolder 'Install-WsusUpdates.ps1'
    Set-Content -Path $scriptPath -Value $ScriptText -Encoding ASCII
    Remove-Item -Path (Join-Path $WorkFolder 'InstallUpdates.result.json') -ErrorAction SilentlyContinue

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Criteria "{1}"' -f $scriptPath, $Criteria
    if ($Reboot) {
        $arguments += ' -Reboot'
    }

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.State -eq 'Running') {
            throw "An update install task is already running on this computer."
        }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Description 'Started by WsusManager: download and install Windows updates.' | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    [pscustomobject]@{
        TaskName  = $TaskName
        State     = [string](Get-ScheduledTask -TaskName $TaskName).State
        LogFile   = Join-Path $WorkFolder 'InstallUpdates.log'
    }
}

$script:InstallResultScript = {
    param([string]$WorkFolder, [string]$TaskName)

    $ErrorActionPreference = 'Stop'
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $info = $null
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
    }
    $resultFile = Join-Path $WorkFolder 'InstallUpdates.result.json'
    $data = $null
    if (Test-Path $resultFile) {
        $data = Get-Content -Path $resultFile -Raw | ConvertFrom-Json
    }

    [pscustomobject]@{
        TaskState      = if ($task) { [string]$task.State } else { 'NotFound' }
        LastRunTime    = if ($info) { $info.LastRunTime } else { $null }
        LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
        Result         = $data
    }
}

$script:RestartScript = {
    param([int]$DelaySeconds, [string]$Message)

    $ErrorActionPreference = 'Stop'
    & shutdown.exe /r /f /t $DelaySeconds /c $Message /d p:2:17
    if ($LASTEXITCODE -ne 0) {
        throw "shutdown.exe exited with code $LASTEXITCODE."
    }
    [pscustomobject]@{ Scheduled = $true }
}

$script:RegistryReadScript = {
    param([object[]]$Settings)

    $ErrorActionPreference = 'Stop'
    foreach ($s in $Settings) {
        $exists = $false
        $value = $null
        $kind = $null
        $err = $null
        try {
            if (Test-Path -LiteralPath $s.Path) {
                $key = Get-Item -LiteralPath $s.Path
                if (@($key.GetValueNames()) -contains $s.Name) {
                    $exists = $true
                    $value = $key.GetValue($s.Name, $null, 'DoNotExpandEnvironmentNames')
                    $kind = [string]$key.GetValueKind($s.Name)
                }
            }
        }
        catch {
            $err = $_.Exception.Message
        }
        [pscustomobject]@{
            Path   = $s.Path
            Name   = $s.Name
            Exists = $exists
            Value  = $value
            Type   = $kind
            Error  = $err
        }
    }
}

$script:RegistryWriteScript = {
    param([object[]]$Settings)

    $ErrorActionPreference = 'Stop'
    foreach ($s in $Settings) {
        $status = 'Applied'
        $err = $null
        try {
            if ($s.Ensure -eq 'Absent') {
                if (Test-Path -LiteralPath $s.Path) {
                    $key = Get-Item -LiteralPath $s.Path
                    if (@($key.GetValueNames()) -contains $s.Name) {
                        Remove-ItemProperty -LiteralPath $s.Path -Name $s.Name -Force
                        $status = 'Removed'
                    }
                }
            }
            else {
                if (-not (Test-Path -LiteralPath $s.Path)) {
                    New-Item -Path $s.Path -Force | Out-Null
                }
                switch ($s.Type) {
                    'DWord' { $v = [int]$s.Value }
                    'QWord' { $v = [long]$s.Value }
                    'MultiString' { $v = [string[]]@($s.Value) }
                    default { $v = [string]$s.Value }
                }
                New-ItemProperty -LiteralPath $s.Path -Name $s.Name -PropertyType $s.Type -Value $v -Force | Out-Null
            }
        }
        catch {
            $status = 'Error'
            $err = $_.Exception.Message
        }
        [pscustomobject]@{ Path = $s.Path; Name = $s.Name; Status = $status; Error = $err }
    }
}

$script:RestartUpdateServiceScript = {
    $ErrorActionPreference = 'Stop'
    Restart-Service -Name wuauserv -Force
    [pscustomobject]@{ Restarted = $true }
}

# --------------------------------------------------------------------------
# WSUS server queries
#
# Every WSUS read goes through one self-contained script block so it can run
# either in-process (when the WSUS administration API / console is installed
# on this machine - "Local" mode) or ON the WSUS server over WinRM ("Remote"
# mode). Remote mode is what lets the portable WsusManager.exe run on a
# workstation that has nothing installed.
# --------------------------------------------------------------------------

$script:WsusQueryScript = {
    param([string]$ServerName, [int]$Port, [bool]$UseSsl, [string]$Query, [hashtable]$Options)

    $ErrorActionPreference = 'Stop'
    if (-not $Options) { $Options = @{} }

    if (Get-Module -ListAvailable -Name UpdateServices) {
        Import-Module UpdateServices -ErrorAction Stop
        $wsus = Get-WsusServer -Name $ServerName -PortNumber $Port -UseSsl:$UseSsl
    }
    else {
        $assembly = [Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
        if (-not $assembly) {
            throw "The WSUS administration API is not installed on $env:COMPUTERNAME."
        }
        $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($ServerName, $UseSsl, $Port)
    }

    $getGroup = {
        param([string]$Name)
        $found = @($wsus.GetComputerTargetGroups() | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
        if (-not $found) {
            throw "WSUS computer group '$Name' was not found."
        }
        $found
    }

    $getComputer = {
        param([string]$Name)
        try {
            $wsus.GetComputerTargetByName($Name)
        }
        catch {
            $match = @($wsus.SearchComputerTargets($Name)) |
                Where-Object { $_.FullDomainName -eq $Name -or $_.FullDomainName -like "$Name.*" } |
                Select-Object -First 1
            if (-not $match) {
                throw "Computer '$Name' is not registered with the WSUS server."
            }
            $match
        }
    }

    $newUpdateScope = {
        $scope = New-Object Microsoft.UpdateServices.Administration.UpdateScope
        $states = [Microsoft.UpdateServices.Administration.ApprovedStates]
        switch ([string]$Options['UpdateApproval']) {
            'Approved' { $scope.ApprovedStates = $states::LatestRevisionApproved }
            'Any' { }
            default { $scope.ApprovedStates = $states::NotApproved -bor $states::LatestRevisionApproved -bor $states::HasStaleUpdateApprovals }
        }
        $scope
    }

    $newGroupScope = {
        $scope = New-Object Microsoft.UpdateServices.Administration.ComputerTargetScope
        [void]$scope.ComputerTargetGroups.Add((& $getGroup ([string]$Options['GroupName'])))
        $scope.IncludeSubgroups = [bool]$Options['IncludeSubgroups']
        $scope
    }

    $computerStatusRow = {
        param($Computer, $Summary)
        $needed = [int]$Summary.NotInstalledCount + [int]$Summary.DownloadedCount
        $status = 'UpToDate'
        if ($Summary.FailedCount -gt 0) { $status = 'Failed' }
        elseif ($needed -gt 0) { $status = 'NeedsUpdates' }
        elseif ($Summary.InstalledPendingRebootCount -gt 0) { $status = 'PendingReboot' }
        elseif ($Summary.UnknownCount -gt 0) { $status = 'Unknown' }

        [pscustomobject]@{
            ComputerName           = $Computer.FullDomainName
            Status                 = $status
            Needed                 = $needed
            Downloaded             = [int]$Summary.DownloadedCount
            Failed                 = [int]$Summary.FailedCount
            InstalledPendingReboot = [int]$Summary.InstalledPendingRebootCount
            Installed              = [int]$Summary.InstalledCount
            Unknown                = [int]$Summary.UnknownCount
            LastSyncTime           = $Computer.LastSyncTime
            LastReportedTime       = $Computer.LastReportedStatusTime
            OperatingSystem        = $Computer.OSDescription
        }
    }

    $updateInfo = {
        param($Update)
        [pscustomobject]@{
            KB             = (@($Update.KnowledgebaseArticles) | Where-Object { $_ } | ForEach-Object { "KB$_" }) -join ','
            Title          = $Update.Title
            Classification = $Update.UpdateClassificationTitle
            Severity       = [string]$Update.MsrcSeverity
            Approved       = [bool]$Update.IsApproved
            Declined       = [bool]$Update.IsDeclined
            Superseded     = [bool]$Update.IsSuperseded
            ReleaseDate    = $Update.CreationDate
            UpdateId       = [string]$Update.Id.UpdateId
        }
    }

    switch ($Query) {
        'Info' {
            $lastSync = $null
            $lastSyncResult = $null
            try {
                $sync = $wsus.GetSubscription().GetLastSynchronizationInfo()
                $lastSync = $sync.EndTime
                $lastSyncResult = [string]$sync.Result
            }
            catch { }
            [pscustomobject]@{
                ServerName     = $wsus.Name
                Port           = $wsus.PortNumber
                Version        = [string]$wsus.Version
                LastSync       = $lastSync
                LastSyncResult = $lastSyncResult
                ComputerCount  = $wsus.GetComputerTargetCount()
                GroupCount     = @($wsus.GetComputerTargetGroups()).Count
            }
        }

        'Groups' {
            foreach ($g in (@($wsus.GetComputerTargetGroups()) | Sort-Object Name)) {
                $parent = $null
                try {
                    $p = $g.GetParentTargetGroup()
                    if ($p) { $parent = $p.Name }
                }
                catch { }
                [pscustomobject]@{
                    Name          = $g.Name
                    ParentGroup   = $parent
                    ComputerCount = @($g.GetComputerTargets()).Count
                    Id            = [string]$g.Id
                }
            }
        }

        'GroupComputers' {
            $group = & $getGroup ([string]$Options['GroupName'])
            foreach ($c in @($group.GetComputerTargets([bool]$Options['IncludeSubgroups']))) {
                [pscustomobject]@{
                    ComputerName     = $c.FullDomainName
                    IPAddress        = [string]$c.IPAddress
                    OperatingSystem  = $c.OSDescription
                    LastSyncTime     = $c.LastSyncTime
                    LastReportedTime = $c.LastReportedStatusTime
                    Group            = $group.Name
                }
            }
        }

        'UpdateStatusGroup' {
            $updateScope = & $newUpdateScope
            $computerScope = & $newGroupScope
            $computers = @{}
            foreach ($c in @($wsus.GetComputerTargets($computerScope))) {
                $computers[[string]$c.Id] = $c
            }
            foreach ($s in @($wsus.GetSummariesPerComputerTarget($updateScope, $computerScope))) {
                $c = $computers[[string]$s.ComputerTargetId]
                if ($c) { & $computerStatusRow $c $s }
            }
        }

        'UpdateStatusComputers' {
            $updateScope = & $newUpdateScope
            foreach ($name in @($Options['ComputerName'])) {
                try {
                    $c = & $getComputer $name
                    $row = & $computerStatusRow $c $c.GetUpdateInstallationSummary($updateScope)
                    $row | Add-Member -NotePropertyName RequestedName -NotePropertyValue $name
                    $row
                }
                catch {
                    [pscustomobject]@{
                        RequestedName = $name; ComputerName = $name; Status = 'NotInWsus'; Needed = $null; Downloaded = $null; Failed = $null
                        InstalledPendingReboot = $null; Installed = $null; Unknown = $null; LastSyncTime = $null
                        LastReportedTime = $null; OperatingSystem = $null
                    }
                }
            }
        }

        'NeededGroup' {
            $updateScope = & $newUpdateScope
            $computerScope = & $newGroupScope
            $rows = foreach ($s in @($wsus.GetSummariesPerUpdate($updateScope, $computerScope))) {
                $needed = [int]$s.NotInstalledCount + [int]$s.DownloadedCount
                if (($needed + [int]$s.FailedCount + [int]$s.InstalledPendingRebootCount) -eq 0) { continue }
                $revision = New-Object Microsoft.UpdateServices.Administration.UpdateRevisionId -ArgumentList ([guid]$s.UpdateId)
                $u = & $updateInfo $wsus.GetUpdate($revision)
                $u | Add-Member -NotePropertyName ComputersNeeding -NotePropertyValue $needed
                $u | Add-Member -NotePropertyName ComputersFailed -NotePropertyValue ([int]$s.FailedCount)
                $u | Add-Member -NotePropertyName ComputersPendingReboot -NotePropertyValue ([int]$s.InstalledPendingRebootCount)
                $u
            }
            $rows | Sort-Object -Property ComputersNeeding -Descending
        }

        'NeededComputer' {
            $updateScope = & $newUpdateScope
            $computer = & $getComputer ([string]$Options['ComputerName'])
            $wanted = @('NotInstalled', 'Downloaded', 'Failed', 'InstalledPendingReboot')
            foreach ($info in @($computer.GetUpdateInstallationInfoPerUpdate($updateScope))) {
                $state = [string]$info.UpdateInstallationState
                if ($wanted -notcontains $state) { continue }
                $u = & $updateInfo $info.GetUpdate()
                $u | Add-Member -NotePropertyName ComputerName -NotePropertyValue $computer.FullDomainName
                $u | Add-Member -NotePropertyName State -NotePropertyValue $state
                $u
            }
        }

        default {
            throw "Unknown WSUS query '$Query'."
        }
    }
}

function Test-WsusManagerLocalApi {
    <#
    .SYNOPSIS
        True when the WSUS administration API is available on this machine.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (Get-Module -ListAvailable -Name UpdateServices) {
        return $true
    }
    try {
        return ($null -ne [Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration'))
    }
    catch {
        return $false
    }
}

function Connect-WsusManagerServer {
    <#
    .SYNOPSIS
        Connects to a WSUS server and keeps the connection for the session.

    .PARAMETER Mode
        Auto (default): use the local WSUS administration API if it is
        installed, otherwise run the queries on the WSUS server over WinRM.
        Local: require the local API. Remote: always use WinRM to the server.

    .PARAMETER ManagementHost
        Remote mode only: the host to open the WinRM session to, if it differs
        from -ServerName (for example a DNS alias that is not a WinRM SPN).

    .EXAMPLE
        Connect-WsusManagerServer -ServerName wsus01 -Port 8530
    .EXAMPLE
        Connect-WsusManagerServer -ServerName wsus01.contoso.com -Port 8531 -UseSsl -Mode Remote
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ServerName,

        [int]$Port = 8530,

        [switch]$UseSsl,

        [ValidateSet('Auto', 'Local', 'Remote')]
        [string]$Mode = 'Auto',

        [string]$ManagementHost,

        [System.Management.Automation.PSCredential]$Credential
    )

    if ($Mode -eq 'Auto') {
        $Mode = if (Test-WsusManagerLocalApi) { 'Local' } else { 'Remote' }
    }
    elseif ($Mode -eq 'Local' -and -not (Test-WsusManagerLocalApi)) {
        throw "The WSUS administration API is not installed here. Install the WSUS console (RSAT: Windows Server Update Services) or use -Mode Remote."
    }

    $previous = $script:WsusConnection
    $script:WsusConnection = [pscustomobject]@{
        ServerName     = $ServerName
        Port           = $Port
        UseSsl         = [bool]$UseSsl
        Mode           = $Mode
        ManagementHost = if ($ManagementHost) { $ManagementHost } else { $ServerName }
        Credential     = $Credential
    }

    try {
        $info = Get-WsusManagerServerInfo
    }
    catch {
        $script:WsusConnection = $previous
        throw "Could not connect to WSUS server '$ServerName' port $Port ($Mode mode): $($_.Exception.Message)"
    }

    Write-WsusManagerLog -Message "Connected to WSUS server $ServerName port $Port (SSL=$([bool]$UseSsl), mode=$Mode)."
    $info
}

function Get-WsusManagerConnection {
    [CmdletBinding()]
    param()

    if (-not $script:WsusConnection) {
        throw 'Not connected to a WSUS server. Run Connect-WsusManagerServer first.'
    }
    $script:WsusConnection
}

function Test-WsusManagerConnected {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $null -ne $script:WsusConnection
}

function Invoke-WsusManagerQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Groups', 'GroupComputers', 'UpdateStatusGroup', 'UpdateStatusComputers', 'NeededGroup', 'NeededComputer')]
        [string]$Query,

        [hashtable]$Options = @{}
    )

    $c = Get-WsusManagerConnection
    $argumentList = @($c.ServerName, $c.Port, $c.UseSsl, $Query, $Options)

    if ($c.Mode -eq 'Local') {
        return (& $script:WsusQueryScript @argumentList)
    }

    $invokeParams = @{
        ComputerName = $c.ManagementHost
        ScriptBlock  = $script:WsusQueryScript
        ArgumentList = $argumentList
        ErrorAction  = 'Stop'
    }
    if ($c.Credential) {
        $invokeParams['Credential'] = $c.Credential
    }
    Invoke-Command @invokeParams | Select-Object -Property * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName
}

function Get-WsusManagerServerUrl {
    <#
    .SYNOPSIS
        Returns the client-facing URL of the connected WSUS server
        (used for the {WsusServerUrl} baseline token).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $c = Get-WsusManagerConnection
    $scheme = if ($c.UseSsl) { 'https' } else { 'http' }
    '{0}://{1}:{2}' -f $scheme, $c.ServerName, $c.Port
}

function Get-WsusManagerServerInfo {
    <#
    .SYNOPSIS
        Shows version, URL, last synchronization and computer/group counts for the connected server.
    #>
    [CmdletBinding()]
    param()

    $c = Get-WsusManagerConnection
    $info = Invoke-WsusManagerQuery -Query Info | Select-Object -First 1
    [pscustomobject]@{
        ServerName     = $info.ServerName
        Port           = $info.Port
        Url            = Get-WsusManagerServerUrl
        Mode           = $c.Mode
        Version        = $info.Version
        LastSync       = $info.LastSync
        LastSyncResult = $info.LastSyncResult
        ComputerCount  = $info.ComputerCount
        GroupCount     = $info.GroupCount
    }
}

# --------------------------------------------------------------------------
# Groups and computers
# --------------------------------------------------------------------------

function Get-WsusManagerGroup {
    <#
    .SYNOPSIS
        Lists the WSUS computer target (update) groups with their computer counts.
    #>
    [CmdletBinding()]
    param()

    Invoke-WsusManagerQuery -Query Groups
}

function Get-WsusManagerGroupComputer {
    <#
    .SYNOPSIS
        Lists the computers in a WSUS group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupName,

        [switch]$IncludeSubgroups
    )

    Invoke-WsusManagerQuery -Query GroupComputers -Options @{ GroupName = $GroupName; IncludeSubgroups = [bool]$IncludeSubgroups }
}

function Resolve-WsusManagerTarget {
    <#
    .SYNOPSIS
        Turns -ComputerName / -GroupName / -ComputerListPath into a unique list of computer names.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$ComputerName,

        [string]$GroupName,

        [string]$ComputerListPath,

        [switch]$IncludeSubgroups
    )

    $names = New-Object System.Collections.Generic.List[string]

    foreach ($n in @($ComputerName)) {
        if ($n -and $n.Trim()) { $names.Add($n.Trim()) }
    }

    if ($ComputerListPath) {
        if (-not (Test-Path -LiteralPath $ComputerListPath)) {
            throw "Computer list file '$ComputerListPath' was not found."
        }
        foreach ($line in (Get-Content -LiteralPath $ComputerListPath)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { $names.Add($t) }
        }
    }

    if ($GroupName) {
        foreach ($c in @(Get-WsusManagerGroupComputer -GroupName $GroupName -IncludeSubgroups:$IncludeSubgroups)) {
            $names.Add($c.ComputerName)
        }
    }

    $unique = @($names | Select-Object -Unique)
    if ($unique.Count -eq 0) {
        throw 'No target computers. Specify -ComputerName, -GroupName or -ComputerListPath.'
    }
    [string[]]$unique
}

# --------------------------------------------------------------------------
# Update information
# --------------------------------------------------------------------------

function Get-WsusManagerUpdateStatus {
    <#
    .SYNOPSIS
        Per-computer update status for a WSUS group (or specific computers) as
        reported to WSUS: needed, downloaded, failed, pending reboot, installed.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Group')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
        [string]$GroupName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Computer')]
        [string[]]$ComputerName,

        [Parameter(ParameterSetName = 'Group')]
        [switch]$IncludeSubgroups,

        [ValidateSet('AnyExceptDeclined', 'Approved', 'Any')]
        [string]$UpdateApproval = 'AnyExceptDeclined'
    )

    if ($PSCmdlet.ParameterSetName -eq 'Group') {
        Invoke-WsusManagerQuery -Query UpdateStatusGroup -Options @{ GroupName = $GroupName; IncludeSubgroups = [bool]$IncludeSubgroups; UpdateApproval = $UpdateApproval }
    }
    else {
        Invoke-WsusManagerQuery -Query UpdateStatusComputers -Options @{ ComputerName = [string[]]$ComputerName; UpdateApproval = $UpdateApproval }
    }
}

function Get-WsusManagerNeededUpdate {
    <#
    .SYNOPSIS
        Lists the updates that computers still need: per group (with how many
        computers need / failed / are pending reboot for each), or per computer.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Group')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
        [string]$GroupName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Computer')]
        [string]$ComputerName,

        [Parameter(ParameterSetName = 'Group')]
        [switch]$IncludeSubgroups,

        [ValidateSet('AnyExceptDeclined', 'Approved', 'Any')]
        [string]$UpdateApproval = 'AnyExceptDeclined'
    )

    if ($PSCmdlet.ParameterSetName -eq 'Computer') {
        Invoke-WsusManagerQuery -Query NeededComputer -Options @{ ComputerName = $ComputerName; UpdateApproval = $UpdateApproval }
    }
    else {
        Invoke-WsusManagerQuery -Query NeededGroup -Options @{ GroupName = $GroupName; IncludeSubgroups = [bool]$IncludeSubgroups; UpdateApproval = $UpdateApproval }
    }
}

# --------------------------------------------------------------------------
# Live client status: reboot needed + uptime
# --------------------------------------------------------------------------

function Get-WsusManagerClientStatus {
    <#
    .SYNOPSIS
        Live status from each computer: online, last boot, system uptime,
        reboot pending (and why), last WU scan / install, wuauserv state and
        the WSUS server the client is pointed at.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [System.Management.Automation.PSCredential]$Credential
    )

    foreach ($row in @(Invoke-WsusManagerRemote -ComputerName $ComputerName -ScriptBlock $script:ClientStatusScript -Credential $Credential)) {
        $r = @($row.Result) | Select-Object -First 1
        $uptime = $null
        $uptimeDays = $null
        if ($row.Success -and $r -and $r.LastBootTime) {
            $span = ([datetime]$r.Now) - ([datetime]$r.LastBootTime)
            $uptime = Format-WsusManagerUptime -TimeSpan $span
            $uptimeDays = [math]::Round($span.TotalDays, 2)
        }

        [pscustomobject]@{
            ComputerName         = $row.ComputerName
            Online               = [bool]$row.Success
            LastBootTime         = if ($r) { $r.LastBootTime } else { $null }
            UptimeDays           = $uptimeDays
            Uptime               = $uptime
            RebootPending        = if ($r) { [bool]$r.RebootPending } else { $null }
            RebootReasons        = if ($r) { $r.RebootReasons } else { $null }
            LastSearchSuccess    = if ($r) { $r.LastSearchSuccess } else { $null }
            LastInstallSuccess   = if ($r) { $r.LastInstallSuccess } else { $null }
            UpdateServiceStatus  = if ($r) { $r.UpdateServiceStatus } else { $null }
            ConfiguredWsusServer = if ($r) { $r.ConfiguredWsusServer } else { $null }
            OperatingSystem      = if ($r) { $r.OperatingSystem } else { $null }
            Error                = if ($row.Success) { if ($r) { $r.Errors } else { $null } } else { $row.Error }
        }
    }
}

function Get-WsusManagerUptimeReport {
    <#
    .SYNOPSIS
        System uptime for each computer, longest first, flagging any over -ThresholdDays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [int]$ThresholdDays = 30,

        [System.Management.Automation.PSCredential]$Credential
    )

    Get-WsusManagerClientStatus -ComputerName $ComputerName -Credential $Credential |
        ForEach-Object {
            [pscustomobject]@{
                ComputerName     = $_.ComputerName
                Online           = $_.Online
                LastBootTime     = $_.LastBootTime
                UptimeDays       = $_.UptimeDays
                Uptime           = $_.Uptime
                ExceedsThreshold = ($null -ne $_.UptimeDays -and $_.UptimeDays -gt $ThresholdDays)
                RebootPending    = $_.RebootPending
                Error            = $_.Error
            }
        } |
        Sort-Object -Property @{ Expression = { if ($null -eq $_.UptimeDays) { -1 } else { $_.UptimeDays } }; Descending = $true }
}

function Merge-WsusManagerRebootRow {
    <#
    .SYNOPSIS
        Combines WSUS-reported pending-reboot counts with live client status
        into one reboot-report row. Pure function (no I/O).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        $WsusStatus,

        $ClientStatus
    )

    $wsusPending = $null
    if ($WsusStatus) {
        $wsusPending = [int]$WsusStatus.InstalledPendingReboot
    }

    $livePending = $null
    if ($ClientStatus -and $ClientStatus.Online) {
        $livePending = [bool]$ClientStatus.RebootPending
    }

    $needed = (($null -ne $wsusPending) -and ($wsusPending -gt 0)) -or ($livePending -eq $true)

    $source = @()
    if ($wsusPending -gt 0) { $source += 'WSUS' }
    if ($livePending) { $source += 'Client' }

    [pscustomobject]@{
        ComputerName              = $ComputerName
        RebootNeeded              = [bool]$needed
        DetectedBy                = ($source -join '+')
        WsusUpdatesPendingReboot  = $wsusPending
        ClientRebootPending       = $livePending
        RebootReasons             = if ($ClientStatus) { $ClientStatus.RebootReasons } else { $null }
        LastBootTime              = if ($ClientStatus) { $ClientStatus.LastBootTime } else { $null }
        UptimeDays                = if ($ClientStatus) { $ClientStatus.UptimeDays } else { $null }
        Uptime                    = if ($ClientStatus) { $ClientStatus.Uptime } else { $null }
        Online                    = if ($ClientStatus) { $ClientStatus.Online } else { $null }
        LastReportedToWsus        = if ($WsusStatus) { $WsusStatus.LastReportedTime } else { $null }
        Error                     = if ($ClientStatus) { $ClientStatus.Error } else { $null }
    }
}

function Get-WsusManagerRebootReport {
    <#
    .SYNOPSIS
        Reboot-needed report with system uptime. Combines what WSUS knows
        (updates installed but pending reboot) with a live check of each
        client's reboot-pending flags and uptime.

    .PARAMETER SkipLiveCheck
        Only use WSUS data (no WinRM to the clients; no uptime).
    #>
    [CmdletBinding()]
    param(
        [string]$GroupName,

        [string[]]$ComputerName,

        [string]$ComputerListPath,

        [switch]$IncludeSubgroups,

        [switch]$SkipLiveCheck,

        [switch]$OnlyRebootNeeded,

        [System.Management.Automation.PSCredential]$Credential
    )

    $targets = Resolve-WsusManagerTarget -ComputerName $ComputerName -GroupName $GroupName -ComputerListPath $ComputerListPath -IncludeSubgroups:$IncludeSubgroups

    $wsusRows = @{}
    if (Test-WsusManagerConnected) {
        $status = if ($GroupName -and -not $ComputerName -and -not $ComputerListPath) {
            Get-WsusManagerUpdateStatus -GroupName $GroupName -IncludeSubgroups:$IncludeSubgroups
        }
        else {
            Get-WsusManagerUpdateStatus -ComputerName $targets
        }
        foreach ($s in @($status)) {
            if ($s.Status -eq 'NotInWsus') { continue }
            # Key by the name the caller used (short name vs. WSUS FQDN).
            $key = if ($s.PSObject.Properties['RequestedName']) { $s.RequestedName } else { $s.ComputerName }
            $wsusRows[$key] = $s
        }
    }
    elseif ($SkipLiveCheck) {
        throw 'Not connected to WSUS and -SkipLiveCheck was given: there is nothing to report from.'
    }

    $clientRows = @{}
    if (-not $SkipLiveCheck) {
        foreach ($c in @(Get-WsusManagerClientStatus -ComputerName $targets -Credential $Credential)) {
            $clientRows[$c.ComputerName] = $c
        }
    }

    $report = foreach ($name in $targets) {
        Merge-WsusManagerRebootRow -ComputerName $name -WsusStatus $wsusRows[$name] -ClientStatus $clientRows[$name]
    }
    if ($OnlyRebootNeeded) {
        $report = @($report | Where-Object { $_.RebootNeeded })
    }
    $report | Sort-Object -Property @{ Expression = 'RebootNeeded'; Descending = $true }, ComputerName
}

# --------------------------------------------------------------------------
# Client actions: check-in, install, reboot
# --------------------------------------------------------------------------

function Invoke-WsusManagerCheckIn {
    <#
    .SYNOPSIS
        Forces Windows Update clients to detect against WSUS and report status now.

    .PARAMETER ResetAuthorization
        Also run 'wuauclt /resetauthorization' (re-evaluates client-side targeting group).

    .PARAMETER WaitForScan
        Run a synchronous WUA scan and return how many updates are applicable.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$ResetAuthorization,

        [switch]$WaitForScan,

        [System.Management.Automation.PSCredential]$Credential
    )

    $targets = @($ComputerName | Where-Object { $PSCmdlet.ShouldProcess($_, 'Force Windows Update detection and status report') })
    if ($targets.Count -eq 0) { return }

    Write-WsusManagerLog -Level ACTION -Message "Check-in requested for: $($targets -join ', ')"
    foreach ($row in @(Invoke-WsusManagerRemote -ComputerName $targets -ScriptBlock $script:CheckInScript -ArgumentList @([bool]$ResetAuthorization, [bool]$WaitForScan) -Credential $Credential)) {
        $r = @($row.Result) | Select-Object -First 1
        [pscustomobject]@{
            ComputerName      = $row.ComputerName
            Success           = [bool]$row.Success
            Actions           = if ($r) { $r.Actions } else { $null }
            ApplicableUpdates = if ($r) { $r.ApplicableUpdates } else { $null }
            Error             = if ($row.Success) { if ($r) { $r.Errors } else { $null } } else { $row.Error }
        }
    }
}

function Invoke-WsusManagerUpdateInstall {
    <#
    .SYNOPSIS
        Forces each computer to download and install its applicable updates now.

    .DESCRIPTION
        Registers and starts a one-off scheduled task running as SYSTEM on each
        target (the Windows Update Agent will not download or install from a
        remote session). Progress is written to
        C:\ProgramData\WsusManager\InstallUpdates.log on the target; use
        Get-WsusManagerUpdateInstallResult to collect the outcome.

    .PARAMETER RebootIfRequired
        Restart the computer (60 second warning) after install if an update requires it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$RebootIfRequired,

        [string]$Criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'",

        [System.Management.Automation.PSCredential]$Credential
    )

    if ($Criteria -match '"') {
        throw 'The -Criteria string cannot contain double quotes.'
    }

    $what = 'Download and install Windows updates'
    if ($RebootIfRequired) { $what += ' and reboot if required' }
    $targets = @($ComputerName | Where-Object { $PSCmdlet.ShouldProcess($_, $what) })
    if ($targets.Count -eq 0) { return }

    Write-WsusManagerLog -Level ACTION -Message "Update install (reboot=$([bool]$RebootIfRequired)) requested for: $($targets -join ', ')"
    $argsList = @($script:ClientWorkFolder, $script:InstallTaskName, $script:InstallUpdatesClientScript, $Criteria, [bool]$RebootIfRequired)
    foreach ($row in @(Invoke-WsusManagerRemote -ComputerName $targets -ScriptBlock $script:StartInstallScript -ArgumentList $argsList -Credential $Credential)) {
        $r = @($row.Result) | Select-Object -First 1
        [pscustomobject]@{
            ComputerName = $row.ComputerName
            Started      = [bool]$row.Success
            TaskState    = if ($r) { $r.State } else { $null }
            ClientLog    = if ($r) { $r.LogFile } else { $null }
            Error        = $row.Error
        }
    }
}

function Get-WsusManagerUpdateInstallResult {
    <#
    .SYNOPSIS
        Collects the outcome of Invoke-WsusManagerUpdateInstall from each computer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [System.Management.Automation.PSCredential]$Credential
    )

    foreach ($row in @(Invoke-WsusManagerRemote -ComputerName $ComputerName -ScriptBlock $script:InstallResultScript -ArgumentList @($script:ClientWorkFolder, $script:InstallTaskName) -Credential $Credential)) {
        $r = @($row.Result) | Select-Object -First 1
        $d = if ($r) { $r.Result } else { $null }
        $failedTitles = $null
        if ($d -and $d.Updates) {
            $failedTitles = (@($d.Updates) | Where-Object { $_.Result -notin 'Succeeded', 'SucceededWithErrors' } | ForEach-Object { $_.Title }) -join '; '
        }
        [pscustomobject]@{
            ComputerName   = $row.ComputerName
            Reachable      = [bool]$row.Success
            TaskState      = if ($r) { $r.TaskState } else { $null }
            Status         = if ($d) { $d.Status } else { $null }
            Found          = if ($d) { $d.Found } else { $null }
            Installed      = if ($d) { $d.Installed } else { $null }
            Failed         = if ($d) { $d.Failed } else { $null }
            RebootRequired = if ($d) { $d.RebootRequired } else { $null }
            RebootStarted  = if ($d) { $d.RebootStarted } else { $null }
            StartTime      = if ($d) { $d.StartTime } else { $null }
            EndTime        = if ($d) { $d.EndTime } else { $null }
            FailedUpdates  = $failedTitles
            Error          = if ($row.Success) { if ($d) { $d.Error } else { $null } } else { $row.Error }
        }
    }
}

function Restart-WsusManagerComputer {
    <#
    .SYNOPSIS
        Forces a reboot of the target computers (logged-on users are not able to cancel it).

    .PARAMETER OnlyIfRebootPending
        Check each computer first and only restart those reporting a pending reboot.

    .PARAMETER DelaySeconds
        Warning period shown to logged-on users before the restart (0-600).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName,

        [switch]$OnlyIfRebootPending,

        [ValidateRange(0, 600)]
        [int]$DelaySeconds = 0,

        [string]$Message = 'This computer is being restarted by IT to complete Windows Update maintenance.',

        [System.Management.Automation.PSCredential]$Credential
    )

    $candidates = @($ComputerName)
    $skipped = @()
    if ($OnlyIfRebootPending) {
        $status = @(Get-WsusManagerClientStatus -ComputerName $ComputerName -Credential $Credential)
        $candidates = @($status | Where-Object { $_.Online -and $_.RebootPending } | ForEach-Object { $_.ComputerName })
        $skipped = @($status | Where-Object { -not ($_.Online -and $_.RebootPending) })
    }

    foreach ($s in $skipped) {
        [pscustomobject]@{
            ComputerName = $s.ComputerName
            Restarted    = $false
            Detail       = if ($s.Online) { 'Skipped - no reboot pending' } else { 'Skipped - offline' }
            Error        = $s.Error
        }
    }

    $targets = @($candidates | Where-Object { $PSCmdlet.ShouldProcess($_, "Force restart in $DelaySeconds second(s)") })
    if ($targets.Count -eq 0) { return }

    Write-WsusManagerLog -Level ACTION -Message "Forced restart (delay ${DelaySeconds}s) requested for: $($targets -join ', ')"
    foreach ($row in @(Invoke-WsusManagerRemote -ComputerName $targets -ScriptBlock $script:RestartScript -ArgumentList @($DelaySeconds, $Message) -Credential $Credential)) {
        [pscustomobject]@{
            ComputerName = $row.ComputerName
            Restarted    = [bool]$row.Success
            Detail       = if ($row.Success) { "Restart scheduled in $DelaySeconds second(s)" } else { 'Failed' }
            Error        = $row.Error
        }
    }
}

# --------------------------------------------------------------------------
# Registry baseline: load, resolve tokens, compare, apply
# --------------------------------------------------------------------------

function Get-WsusManagerDefaultBaselinePath {
    <#
    .SYNOPSIS
        Finds WsusClientBaseline.json next to the module, or next to the
        running exe / current directory for the portable build. $null if none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Inside the PS2EXE-compiled exe $PSScriptRoot may be undefined, which
    # StrictMode turns into an error - hence the guarded read.
    $moduleFolder = $null
    try { $moduleFolder = $PSScriptRoot } catch { }

    $folders = @(
        $moduleFolder
        [System.AppDomain]::CurrentDomain.BaseDirectory
        (Get-Location).ProviderPath
    )
    foreach ($folder in $folders) {
        if (-not $folder) { continue }
        $candidate = Join-Path $folder $script:BaselineFileName
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    $null
}

function Import-WsusManagerBaseline {
    <#
    .SYNOPSIS
        Loads and validates a Windows Update registry baseline JSON file.
    #>
    [CmdletBinding()]
    param(
        # Omit to use WsusClientBaseline.json next to the module / exe, or the
        # copy embedded in the portable exe.
        [string]$Path
    )

    if (-not $Path) {
        $Path = Get-WsusManagerDefaultBaselinePath
    }

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Baseline file '$Path' was not found."
        }
        $source = (Resolve-Path -LiteralPath $Path).Path
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    elseif ($script:EmbeddedBaselineJson) {
        $source = '(embedded default baseline)'
        $Path = $source
        $json = $script:EmbeddedBaselineJson | ConvertFrom-Json
    }
    else {
        throw "No baseline file given and no $($script:BaselineFileName) was found."
    }
    if (-not $json.PSObject.Properties['Settings'] -or -not $json.Settings) {
        throw "Baseline '$Path' has no Settings array."
    }

    $settings = foreach ($s in @($json.Settings)) {
        foreach ($required in 'Path', 'Name') {
            if (-not $s.PSObject.Properties[$required] -or -not $s.$required) {
                throw "Baseline '$Path': a setting is missing '$required'."
            }
        }

        $ensure = 'Present'
        if ($s.PSObject.Properties['Ensure'] -and $s.Ensure) { $ensure = [string]$s.Ensure }
        if ($ensure -notin 'Present', 'Absent') {
            throw "Baseline setting $($s.Name): Ensure must be 'Present' or 'Absent'."
        }

        $type = $null
        $value = $null
        $allowed = $null
        if ($ensure -eq 'Present') {
            if (-not $s.PSObject.Properties['Type'] -or $script:SupportedValueTypes -notcontains $s.Type) {
                throw "Baseline setting $($s.Name): Type must be one of $($script:SupportedValueTypes -join ', ')."
            }
            if (-not $s.PSObject.Properties['Value']) {
                throw "Baseline setting $($s.Name): Value is required when Ensure is Present."
            }
            $type = [string]$s.Type
            $value = $s.Value
            if ($s.PSObject.Properties['AllowedValues'] -and $null -ne $s.AllowedValues) {
                $allowed = @($s.AllowedValues)
            }
        }

        $path = [string]$s.Path
        if ($path -notmatch '^(HKLM|HKEY_LOCAL_MACHINE):?\\') {
            throw "Baseline setting $($s.Name): only HKLM paths are supported (got '$path')."
        }
        $path = $path -replace '^(HKLM|HKEY_LOCAL_MACHINE):?\\', 'HKLM:\'

        [pscustomobject]@{
            Path          = $path
            Name          = [string]$s.Name
            Ensure        = $ensure
            Type          = $type
            Value         = $value
            AllowedValues = $allowed
            Description   = if ($s.PSObject.Properties['Description']) { [string]$s.Description } else { $null }
        }
    }

    [pscustomobject]@{
        Name        = if ($json.PSObject.Properties['Name']) { [string]$json.Name } else { 'Baseline' }
        Description = if ($json.PSObject.Properties['Description']) { [string]$json.Description } else { $null }
        Path        = $source
        Settings    = @($settings)
    }
}

function Resolve-WsusManagerBaseline {
    <#
    .SYNOPSIS
        Replaces {Token} placeholders in baseline values (e.g. {WsusServerUrl},
        {TargetGroup}). Throws if a token is used but has no value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Settings,

        [hashtable]$Tokens = @{}
    )

    $replace = {
        param($text)
        if ($text -isnot [string]) { return $text }
        $out = $text
        foreach ($m in [regex]::Matches($text, '\{(\w+)\}')) {
            $token = $m.Groups[1].Value
            if (-not $Tokens.ContainsKey($token) -or [string]::IsNullOrEmpty([string]$Tokens[$token])) {
                throw "Baseline value uses {$token} but no value was supplied for it."
            }
            $out = $out.Replace($m.Value, [string]$Tokens[$token])
        }
        $out
    }

    foreach ($s in $Settings) {
        $copy = $s.PSObject.Copy()
        if ($copy.Ensure -eq 'Present') {
            if ($copy.Value -is [array]) {
                $copy.Value = @($copy.Value | ForEach-Object { & $replace $_ })
            }
            else {
                $copy.Value = & $replace $copy.Value
            }
            if ($copy.AllowedValues) {
                $copy.AllowedValues = @($copy.AllowedValues | ForEach-Object { & $replace $_ })
            }
        }
        $copy
    }
}

function Test-WsusManagerValueMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Type,
        $Expected,
        $Actual
    )

    switch ($Type) {
        { $_ -in 'DWord', 'QWord' } {
            try {
                # DWORDs read back as Int32; treat negative values as their unsigned form.
                $a = [int64]$Actual
                if ($Type -eq 'DWord' -and $a -lt 0) { $a += 4294967296 }
                return ([int64]$Expected -eq $a)
            }
            catch {
                return $false
            }
        }
        'MultiString' {
            $e = @($Expected | ForEach-Object { [string]$_ }) -join "`n"
            $a = @($Actual | ForEach-Object { [string]$_ }) -join "`n"
            return ($e -eq $a)
        }
        default {
            return (([string]$Expected).Trim() -eq ([string]$Actual).Trim())
        }
    }
}

function Compare-WsusManagerRegistryValue {
    <#
    .SYNOPSIS
        Compares one actual registry value against one baseline setting.
        Pure function: returns Status (Compliant / NonCompliant / Missing) and Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Setting,

        [bool]$Exists,

        $ActualValue,

        [string]$ActualType
    )

    $status = 'Compliant'
    $detail = $null

    if ($Setting.Ensure -eq 'Absent') {
        if ($Exists) {
            $status = 'NonCompliant'
            $detail = 'Value is present but should be absent.'
        }
    }
    elseif (-not $Exists) {
        $status = 'Missing'
        $detail = 'Value is not set.'
    }
    elseif ($ActualType -and $ActualType -ne $Setting.Type) {
        $status = 'NonCompliant'
        $detail = "Type is $ActualType, expected $($Setting.Type)."
    }
    else {
        $candidates = if ($Setting.AllowedValues) { @($Setting.AllowedValues) } else { @(, $Setting.Value) }
        $ok = $false
        foreach ($c in $candidates) {
            if (Test-WsusManagerValueMatch -Type $Setting.Type -Expected $c -Actual $ActualValue) {
                $ok = $true
                break
            }
        }
        if (-not $ok) {
            $status = 'NonCompliant'
            $detail = 'Value does not match baseline.'
        }
    }

    [pscustomobject]@{ Status = $status; Detail = $detail }
}

function Format-WsusManagerRegistryValue {
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [array]) { return (@($Value) -join ' | ') }
    [string]$Value
}

function Get-WsusManagerBaselineToken {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$WsusServerUrl,
        [string]$TargetGroup,
        [hashtable]$Tokens
    )

    $t = @{}
    if ($Tokens) {
        foreach ($k in $Tokens.Keys) { $t[$k] = $Tokens[$k] }
    }
    if ($WsusServerUrl) {
        $t['WsusServerUrl'] = $WsusServerUrl.TrimEnd('/')
    }
    elseif (-not $t.ContainsKey('WsusServerUrl') -and (Test-WsusManagerConnected)) {
        $t['WsusServerUrl'] = Get-WsusManagerServerUrl
    }
    if ($TargetGroup) {
        $t['TargetGroup'] = $TargetGroup
    }
    $t
}

function Test-WsusManagerRegistryCompliance {
    <#
    .SYNOPSIS
        Checks each computer's Windows Update policy registry values against the
        baseline. One row per computer per setting.

    .PARAMETER WsusServerUrl
        Value for the {WsusServerUrl} token. Defaults to the connected WSUS server.

    .PARAMETER TargetGroup
        Value for the {TargetGroup} token. Defaults to -GroupName when targeting a group.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ComputerName,

        [string]$GroupName,

        [string]$ComputerListPath,

        [switch]$IncludeSubgroups,

        [string]$BaselinePath,

        [string]$WsusServerUrl,

        [string]$TargetGroup,

        [hashtable]$Tokens,

        [System.Management.Automation.PSCredential]$Credential
    )

    $targets = Resolve-WsusManagerTarget -ComputerName $ComputerName -GroupName $GroupName -ComputerListPath $ComputerListPath -IncludeSubgroups:$IncludeSubgroups
    if (-not $TargetGroup -and $GroupName) { $TargetGroup = $GroupName }

    $baseline = Import-WsusManagerBaseline -Path $BaselinePath
    $tokenTable = Get-WsusManagerBaselineToken -WsusServerUrl $WsusServerUrl -TargetGroup $TargetGroup -Tokens $Tokens
    $settings = @(Resolve-WsusManagerBaseline -Settings $baseline.Settings -Tokens $tokenTable)
    $readArgs = @(, [object[]]@($settings | Select-Object Path, Name))

    foreach ($row in @(Invoke-WsusManagerRemote -ComputerName $targets -ScriptBlock $script:RegistryReadScript -ArgumentList $readArgs -Credential $Credential)) {
        $actual = @{}
        foreach ($a in @($row.Result)) { $actual["$($a.Path)|$($a.Name)"] = $a }

        foreach ($s in $settings) {
            $expected = if ($s.Ensure -eq 'Absent') { '(absent)' } elseif ($s.AllowedValues) { 'one of: ' + (@($s.AllowedValues) -join ', ') } else { Format-WsusManagerRegistryValue $s.Value }

            if (-not $row.Success) {
                $status = 'Error'
                $detail = $row.Error
                $a = $null
            }
            else {
                $a = $actual["$($s.Path)|$($s.Name)"]
                if (-not $a -or $a.Error) {
                    $status = 'Error'
                    $detail = if ($a) { $a.Error } else { 'Value was not read.' }
                }
                else {
                    $cmp = Compare-WsusManagerRegistryValue -Setting $s -Exists ([bool]$a.Exists) -ActualValue $a.Value -ActualType $a.Type
                    $status = $cmp.Status
                    $detail = $cmp.Detail
                }
            }

            [pscustomobject]@{
                ComputerName = $row.ComputerName
                Setting      = $s.Name
                Path         = $s.Path
                Expected     = $expected
                Actual       = if ($a -and $a.Exists) { Format-WsusManagerRegistryValue $a.Value } else { $null }
                ActualType   = if ($a) { $a.Type } else { $null }
                Status       = $status
                Detail       = $detail
                Description  = $s.Description
            }
        }
    }
}

function Get-WsusManagerComplianceSummary {
    <#
    .SYNOPSIS
        Rolls Test-WsusManagerRegistryCompliance rows up to one row per computer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object[]]$InputObject
    )

    begin { $all = New-Object System.Collections.Generic.List[object] }
    process { foreach ($i in $InputObject) { $all.Add($i) } }
    end {
        foreach ($g in ($all | Group-Object -Property ComputerName)) {
            $rows = @($g.Group)
            $compliant = @($rows | Where-Object { $_.Status -eq 'Compliant' }).Count
            $nonCompliant = @($rows | Where-Object { $_.Status -eq 'NonCompliant' }).Count
            $missing = @($rows | Where-Object { $_.Status -eq 'Missing' }).Count
            $errors = @($rows | Where-Object { $_.Status -eq 'Error' }).Count
            $total = $rows.Count

            $overall = if ($errors -eq $total) { 'Unreachable' }
                elseif ($errors -gt 0) { 'Error' }
                elseif ($compliant -eq $total) { 'Compliant' }
                else { 'NonCompliant' }

            [pscustomobject]@{
                ComputerName      = $g.Name
                Status            = $overall
                CompliancePercent = if ($total) { [math]::Round(100 * $compliant / $total, 1) } else { 0 }
                Compliant         = $compliant
                NonCompliant      = $nonCompliant
                Missing           = $missing
                Errors            = $errors
                FailedSettings    = (@($rows | Where-Object { $_.Status -ne 'Compliant' } | ForEach-Object { $_.Setting }) -join ', ')
            }
        }
    }
}

function Set-WsusManagerClientRegistry {
    <#
    .SYNOPSIS
        Applies the Windows Update registry baseline to each computer. Only
        settings that are not already compliant are written; the previous values
        are backed up to a CSV in the log directory first.

    .NOTES
        Values under HKLM\SOFTWARE\Policies are normally owned by Group Policy.
        If a GPO configures the same setting it will overwrite these on the
        next policy refresh - fix the GPO instead in that case.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string[]]$ComputerName,

        [string]$GroupName,

        [string]$ComputerListPath,

        [switch]$IncludeSubgroups,

        [string]$BaselinePath,

        [string]$WsusServerUrl,

        [string]$TargetGroup,

        [hashtable]$Tokens,

        [switch]$RestartUpdateService,

        [switch]$CheckIn,

        [System.Management.Automation.PSCredential]$Credential
    )

    $targets = Resolve-WsusManagerTarget -ComputerName $ComputerName -GroupName $GroupName -ComputerListPath $ComputerListPath -IncludeSubgroups:$IncludeSubgroups
    if (-not $TargetGroup -and $GroupName) { $TargetGroup = $GroupName }

    $baseline = Import-WsusManagerBaseline -Path $BaselinePath
    $tokenTable = Get-WsusManagerBaselineToken -WsusServerUrl $WsusServerUrl -TargetGroup $TargetGroup -Tokens $Tokens
    $settings = @(Resolve-WsusManagerBaseline -Settings $baseline.Settings -Tokens $tokenTable)

    $before = @(Test-WsusManagerRegistryCompliance -ComputerName $targets -BaselinePath $BaselinePath -WsusServerUrl $tokenTable['WsusServerUrl'] -TargetGroup $TargetGroup -Tokens $tokenTable -Credential $Credential)

    try {
        $dir = Get-WsusManagerLogDirectory
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
        $backup = Join-Path $dir ('RegistryBackup-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $before | Export-Csv -LiteralPath $backup -NoTypeInformation -WhatIf:$false
        Write-WsusManagerLog -Message "Registry values before change saved to $backup"
    }
    catch {
        Write-Warning "Could not write registry backup: $($_.Exception.Message)"
    }

    $settingByKey = @{}
    foreach ($s in $settings) { $settingByKey["$($s.Path)|$($s.Name)"] = $s }

    foreach ($computerRows in ($before | Group-Object -Property ComputerName)) {
        $computer = $computerRows.Name
        $rows = @($computerRows.Group)

        if (@($rows | Where-Object { $_.Status -eq 'Error' }).Count -eq $rows.Count) {
            [pscustomobject]@{ ComputerName = $computer; Setting = '*'; Status = 'Unreachable'; Previous = $null; New = $null; Error = $rows[0].Detail }
            continue
        }

        $toFix = @($rows | Where-Object { $_.Status -in 'NonCompliant', 'Missing' } | ForEach-Object { $settingByKey["$($_.Path)|$($_.Setting)"] })
        if ($toFix.Count -eq 0) {
            [pscustomobject]@{ ComputerName = $computer; Setting = '*'; Status = 'AlreadyCompliant'; Previous = $null; New = $null; Error = $null }
            continue
        }

        $names = ($toFix | ForEach-Object { $_.Name }) -join ', '
        if (-not $PSCmdlet.ShouldProcess($computer, "Set Windows Update registry values: $names")) {
            foreach ($s in $toFix) {
                $prev = $rows | Where-Object { $_.Setting -eq $s.Name -and $_.Path -eq $s.Path } | Select-Object -First 1
                [pscustomobject]@{ ComputerName = $computer; Setting = $s.Name; Status = 'WouldChange'; Previous = $prev.Actual; New = $prev.Expected; Error = $null }
            }
            continue
        }

        Write-WsusManagerLog -Level ACTION -Message "Writing registry baseline on ${computer}: $names"
        $writeArgs = @(, [object[]]@($toFix | Select-Object Path, Name, Ensure, Type, Value))
        $result = @(Invoke-WsusManagerRemote -ComputerName $computer -ScriptBlock $script:RegistryWriteScript -ArgumentList $writeArgs -Credential $Credential) | Select-Object -First 1

        foreach ($s in $toFix) {
            $prev = $rows | Where-Object { $_.Setting -eq $s.Name -and $_.Path -eq $s.Path } | Select-Object -First 1
            $w = @($result.Result) | Where-Object { $_.Name -eq $s.Name -and $_.Path -eq $s.Path } | Select-Object -First 1
            [pscustomobject]@{
                ComputerName = $computer
                Setting      = $s.Name
                Status       = if (-not $result.Success) { 'Error' } elseif ($w) { $w.Status } else { 'Unknown' }
                Previous     = $prev.Actual
                New          = $prev.Expected
                Error        = if (-not $result.Success) { $result.Error } elseif ($w) { $w.Error } else { $null }
            }
        }

        if ($result.Success -and $RestartUpdateService) {
            [void](Invoke-WsusManagerRemote -ComputerName $computer -ScriptBlock $script:RestartUpdateServiceScript -Credential $Credential)
        }
        if ($result.Success -and $CheckIn) {
            [void](Invoke-WsusManagerCheckIn -ComputerName $computer -Credential $Credential -Confirm:$false)
        }
    }
}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

function Export-WsusManagerReport {
    <#
    .SYNOPSIS
        Exports report rows to .csv, .html or .json (chosen by file extension).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Title = 'WSUS Manager Report'
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        '.csv' {
            $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -WhatIf:$false
        }
        '.json' {
            ConvertTo-Json -InputObject @($InputObject) -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8 -WhatIf:$false
        }
        { $_ -in '.html', '.htm' } {
            $css = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; margin: 20px; color: #222; }
h1 { font-size: 20px; margin-bottom: 4px; }
p.meta { color: #666; margin-top: 0; }
table { border-collapse: collapse; width: 100%; }
th { background: #2f4f6f; color: #fff; text-align: left; padding: 6px 8px; }
td { border-bottom: 1px solid #ddd; padding: 5px 8px; vertical-align: top; }
tr:nth-child(even) td { background: #f6f8fa; }
td.good { color: #1a7f37; font-weight: 600; }
td.bad { color: #c62828; font-weight: 600; }
td.warn { color: #b26a00; font-weight: 600; }
</style>
'@
            $pre = "<h1>$([System.Net.WebUtility]::HtmlEncode($Title))</h1><p class='meta'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $([System.Net.WebUtility]::HtmlEncode([string]$env:COMPUTERNAME)) - $(@($InputObject).Count) row(s)</p>"
            $html = $InputObject | ConvertTo-Html -Title $Title -Head $css -PreContent $pre | Out-String
            foreach ($good in 'Compliant', 'UpToDate', 'AlreadyCompliant', 'Applied') {
                $html = $html.Replace("<td>$good</td>", "<td class=""good"">$good</td>")
            }
            foreach ($bad in 'NonCompliant', 'Missing', 'Failed', 'Unreachable', 'Error') {
                $html = $html.Replace("<td>$bad</td>", "<td class=""bad"">$bad</td>")
            }
            foreach ($warn in 'NeedsUpdates', 'PendingReboot', 'WouldChange') {
                $html = $html.Replace("<td>$warn</td>", "<td class=""warn"">$warn</td>")
            }
            Set-Content -LiteralPath $Path -Value $html -Encoding UTF8 -WhatIf:$false
        }
        default {
            throw "Unsupported report format '$extension'. Use .csv, .html or .json."
        }
    }

    Write-WsusManagerLog -Message "Report exported to $Path"
    Get-Item -LiteralPath $Path
}

# --------------------------------------------------------------------------
# Interactive menu
# --------------------------------------------------------------------------

function Read-WsusManagerTarget {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '  Target: [G] WSUS group  [C] computer name(s)  [F] computer list file' -ForegroundColor Cyan
    $kind = (Read-Host '  Choose').Trim().ToUpperInvariant()
    switch ($kind) {
        'G' {
            if (-not (Test-WsusManagerConnected)) { throw 'Connect to WSUS first to target a group.' }
            Get-WsusManagerGroup | Format-Table Name, ParentGroup, ComputerCount -AutoSize | Out-Host
            $g = Read-Host '  Group name'
            $sub = (Read-Host '  Include subgroups? [y/N]') -match '^[Yy]'
            return @{ GroupName = $g; IncludeSubgroups = [bool]$sub }
        }
        'C' {
            $raw = Read-Host '  Computer name(s), comma separated'
            return @{ ComputerName = @($raw -split '[,; ]+' | Where-Object { $_ }) }
        }
        'F' {
            return @{ ComputerListPath = (Read-Host '  Path to file (one name per line)') }
        }
        default { throw 'Unknown target choice.' }
    }
}

function Get-WsusManagerSettingsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $base = $env:APPDATA
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    Join-Path (Join-Path $base 'WsusManager') 'settings.json'
}

function Get-WsusManagerSavedServer {
    <#
    .SYNOPSIS
        Returns the last WSUS server this user connected to (or $null).
    #>
    [CmdletBinding()]
    param()

    try {
        $path = Get-WsusManagerSettingsPath
        if (Test-Path -LiteralPath $path) {
            return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        }
    }
    catch { }
    $null
}

function Save-WsusManagerServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [int]$Port = 8530,

        [bool]$UseSsl,

        [string]$Mode = 'Auto'
    )

    try {
        $path = Get-WsusManagerSettingsPath
        if ($PSCmdlet.ShouldProcess($path, 'Remember WSUS server')) {
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [pscustomobject]@{ ServerName = $ServerName; Port = $Port; UseSsl = $UseSsl; Mode = $Mode } |
                ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
        }
    }
    catch {
        Write-Verbose "Could not save settings: $($_.Exception.Message)"
    }
}

function Read-WsusManagerConnection {
    <#
    .SYNOPSIS
        Prompts for the WSUS server to use (defaulting to the last one used) and connects.
    #>
    [CmdletBinding()]
    param(
        [System.Management.Automation.PSCredential]$Credential,

        [switch]$AllowSkip
    )

    $saved = Get-WsusManagerSavedServer
    $defaultName = if ($saved) { [string]$saved.ServerName } else { '' }
    $defaultPort = if ($saved -and $saved.Port) { [int]$saved.Port } else { 8530 }
    $defaultSsl = if ($saved) { [bool]$saved.UseSsl } else { $false }

    $prompt = if ($defaultName) { "  WSUS server name [$defaultName]" } else { '  WSUS server name' }
    $name = (Read-Host $prompt).Trim()
    if (-not $name) { $name = $defaultName }
    if (-not $name) {
        if ($AllowSkip) { return }
        throw 'A WSUS server name is required.'
    }

    $portText = (Read-Host "  Port [$defaultPort] (8530 = HTTP, 8531 = HTTPS)").Trim()
    $port = if ($portText) { [int]$portText } else { $defaultPort }

    $sslDefault = if ($defaultSsl -or $port -eq 8531) { 'Y' } else { 'N' }
    $sslText = (Read-Host "  Use SSL? [$sslDefault]").Trim()
    $ssl = if ($sslText) { $sslText -match '^[Yy]' } else { $sslDefault -eq 'Y' }

    $mode = 'Auto'
    if (-not (Test-WsusManagerLocalApi)) {
        Write-Host "  WSUS console not installed here - WSUS queries will run on $name over WinRM." -ForegroundColor DarkGray
    }

    $info = Connect-WsusManagerServer -ServerName $name -Port $port -UseSsl:$ssl -Mode $mode -Credential $Credential
    Save-WsusManagerServer -ServerName $name -Port $port -UseSsl $ssl -Mode $mode -Confirm:$false
    $info
}

function Show-WsusManagerResult {
    [CmdletBinding()]
    param(
        $Result
    )

    $script:LastResult = @($Result)
    if (@($Result).Count -eq 0) {
        Write-Host '  (no results)' -ForegroundColor DarkGray
        return
    }
    $Result | Format-Table -AutoSize -Wrap | Out-Host
    Write-Host "  $(@($Result).Count) row(s). Use [E] to export." -ForegroundColor DarkGray
}

function Show-WsusManagerMenu {
    <#
    .SYNOPSIS
        Interactive console menu for every WsusManager feature.
    #>
    [CmdletBinding()]
    param(
        [string]$BaselinePath,

        [System.Management.Automation.PSCredential]$Credential
    )

    $cred = @{}
    if ($Credential) { $cred['Credential'] = $Credential }

    if (-not (Test-WsusManagerConnected)) {
        Write-Host ''
        Write-Host '  Which WSUS server should this session use? (leave the name blank to skip)' -ForegroundColor Cyan
        try {
            $info = Read-WsusManagerConnection -Credential $Credential -AllowSkip
            if ($info) { Show-WsusManagerResult $info }
        }
        catch {
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  Use option 1 to try again. Client-side options still work without WSUS.' -ForegroundColor DarkGray
        }
    }

    while ($true) {
        $connected = if (Test-WsusManagerConnected) { "$($script:WsusConnection.ServerName):$($script:WsusConnection.Port) ($($script:WsusConnection.Mode) mode)" } else { 'not connected' }
        Write-Host ''
        Write-Host '  ================= WSUS Manager =================' -ForegroundColor Cyan
        Write-Host "  WSUS: $connected" -ForegroundColor DarkCyan
        Write-Host '  ------------------ WSUS server -----------------'
        Write-Host '   1  Connect to WSUS server / server info'
        Write-Host '   2  List update groups'
        Write-Host '   3  Update status per computer (group)'
        Write-Host '   4  Needed updates for a group'
        Write-Host '   5  Needed updates for one computer'
        Write-Host '  -------------------- Reports -------------------'
        Write-Host '   6  Reboot-needed report (with uptime)'
        Write-Host '   7  System uptime report'
        Write-Host '   8  Live client status'
        Write-Host '  -------------------- Actions -------------------'
        Write-Host '   9  Force check-in (detect + report now)'
        Write-Host '  10  Force update install'
        Write-Host '  11  Update install results'
        Write-Host '  12  Force reboot'
        Write-Host '  -------------- Registry settings ---------------'
        Write-Host '  13  Show registry baseline'
        Write-Host '  14  Apply registry baseline'
        Write-Host '  15  Registry compliance report'
        Write-Host '  ------------------------------------------------'
        Write-Host '   E  Export last result    Q  Quit'
        $choice = (Read-Host '  Select').Trim().ToUpperInvariant()

        try {
            switch ($choice) {
                '1' {
                    if ((Test-WsusManagerConnected) -and (Read-Host '  Already connected. Reconnect? [y/N]') -notmatch '^[Yy]') {
                        Show-WsusManagerResult (Get-WsusManagerServerInfo)
                        break
                    }
                    Show-WsusManagerResult (Read-WsusManagerConnection -Credential $Credential)
                }
                '2' { Show-WsusManagerResult (Get-WsusManagerGroup) }
                '3' {
                    $g = Read-Host '  Group name'
                    Show-WsusManagerResult (Get-WsusManagerUpdateStatus -GroupName $g | Select-Object ComputerName, Status, Needed, Failed, InstalledPendingReboot, Installed, LastReportedTime)
                }
                '4' {
                    $g = Read-Host '  Group name'
                    Show-WsusManagerResult (Get-WsusManagerNeededUpdate -GroupName $g | Select-Object KB, Title, Classification, Severity, Approved, ComputersNeeding, ComputersFailed, ComputersPendingReboot)
                }
                '5' {
                    $c = Read-Host '  Computer name'
                    Show-WsusManagerResult (Get-WsusManagerNeededUpdate -ComputerName $c | Select-Object KB, Title, Classification, Severity, State, Approved)
                }
                '6' {
                    $t = Read-WsusManagerTarget
                    Show-WsusManagerResult (Get-WsusManagerRebootReport @t @cred | Select-Object ComputerName, RebootNeeded, DetectedBy, WsusUpdatesPendingReboot, RebootReasons, Uptime, LastBootTime, Online)
                }
                '7' {
                    $t = Read-WsusManagerTarget
                    $days = Read-Host '  Flag uptime over how many days? [30]'
                    $threshold = if ($days) { [int]$days } else { 30 }
                    Show-WsusManagerResult (Get-WsusManagerUptimeReport -ComputerName (Resolve-WsusManagerTarget @t) -ThresholdDays $threshold @cred)
                }
                '8' {
                    $t = Read-WsusManagerTarget
                    Show-WsusManagerResult (Get-WsusManagerClientStatus -ComputerName (Resolve-WsusManagerTarget @t) @cred)
                }
                '9' {
                    $t = Read-WsusManagerTarget
                    $reset = (Read-Host '  Also reset authorization (re-evaluate target group)? [y/N]') -match '^[Yy]'
                    $wait = (Read-Host '  Wait for a full scan (slower, returns applicable count)? [y/N]') -match '^[Yy]'
                    Show-WsusManagerResult (Invoke-WsusManagerCheckIn -ComputerName (Resolve-WsusManagerTarget @t) -ResetAuthorization:$reset -WaitForScan:$wait @cred)
                }
                '10' {
                    $t = Read-WsusManagerTarget
                    $reboot = (Read-Host '  Reboot automatically if required? [y/N]') -match '^[Yy]'
                    Show-WsusManagerResult (Invoke-WsusManagerUpdateInstall -ComputerName (Resolve-WsusManagerTarget @t) -RebootIfRequired:$reboot @cred)
                }
                '11' {
                    $t = Read-WsusManagerTarget
                    Show-WsusManagerResult (Get-WsusManagerUpdateInstallResult -ComputerName (Resolve-WsusManagerTarget @t) @cred)
                }
                '12' {
                    $t = Read-WsusManagerTarget
                    $only = (Read-Host '  Only computers with a reboot pending? [Y/n]') -notmatch '^[Nn]'
                    $delayText = Read-Host '  Warning delay in seconds [0]'
                    $delay = if ($delayText) { [int]$delayText } else { 0 }
                    Show-WsusManagerResult (Restart-WsusManagerComputer -ComputerName (Resolve-WsusManagerTarget @t) -OnlyIfRebootPending:$only -DelaySeconds $delay @cred)
                }
                '13' {
                    $b = Import-WsusManagerBaseline -Path $BaselinePath
                    Write-Host "  Baseline: $($b.Name) ($($b.Path))" -ForegroundColor DarkCyan
                    Show-WsusManagerResult ($b.Settings | Select-Object Name, Ensure, Type, Value, AllowedValues, Path)
                }
                '14' {
                    $t = Read-WsusManagerTarget
                    $url = Read-Host '  WSUS URL for {WsusServerUrl} [blank = connected server]'
                    $tg = Read-Host '  Target group for {TargetGroup} [blank = selected group]'
                    $preview = @(Set-WsusManagerClientRegistry @t -BaselinePath $BaselinePath -WsusServerUrl $url -TargetGroup $tg -WhatIf @cred)
                    Show-WsusManagerResult $preview
                    if (@($preview | Where-Object { $_.Status -eq 'WouldChange' }).Count -gt 0 -and (Read-Host '  Apply these changes? [y/N]') -match '^[Yy]') {
                        $restart = (Read-Host '  Restart wuauserv and check in afterwards? [Y/n]') -notmatch '^[Nn]'
                        Show-WsusManagerResult (Set-WsusManagerClientRegistry @t -BaselinePath $BaselinePath -WsusServerUrl $url -TargetGroup $tg -RestartUpdateService:$restart -CheckIn:$restart -Confirm:$false @cred)
                    }
                }
                '15' {
                    $t = Read-WsusManagerTarget
                    $url = Read-Host '  WSUS URL for {WsusServerUrl} [blank = connected server]'
                    $tg = Read-Host '  Target group for {TargetGroup} [blank = selected group]'
                    $detail = @(Test-WsusManagerRegistryCompliance @t -BaselinePath $BaselinePath -WsusServerUrl $url -TargetGroup $tg @cred)
                    $detail | Get-WsusManagerComplianceSummary | Format-Table -AutoSize | Out-Host
                    Show-WsusManagerResult ($detail | Where-Object { $_.Status -ne 'Compliant' } | Select-Object ComputerName, Setting, Status, Expected, Actual, Detail)
                    $script:LastResult = $detail
                    Write-Host '  (Export [E] includes every setting, compliant ones too.)' -ForegroundColor DarkGray
                }
                'E' {
                    if (-not $script:LastResult) {
                        Write-Host '  Nothing to export yet.' -ForegroundColor Yellow
                        break
                    }
                    $path = Read-Host '  Export path (.csv, .html or .json)'
                    $file = Export-WsusManagerReport -InputObject $script:LastResult -Path $path
                    Write-Host "  Saved $($file.FullName)" -ForegroundColor Green
                }
                'Q' { return }
                default { Write-Host '  Unknown option.' -ForegroundColor Yellow }
            }
        }
        catch {
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-WsusManagerLog -Level ERROR -Message $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function @(
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
