<#
.SYNOPSIS
    Sends a maintenance notification email through an SMTP server.

.DESCRIPTION
    Intended for use with Windows Task Scheduler (see
    SystemRebootTask_and_Email.ps1, which runs this script as one action of a
    scheduled reboot task) or other unattended automation. Logs every attempt,
    success or failure, to a timestamped log file so a headless run that fails
    still leaves a trace.

.PARAMETER From
    Sender address, e.g. 'ServerName <ServerName@domain.com>'.

.PARAMETER To
    One or more recipient addresses.

.PARAMETER SmtpServer
    SMTP relay/server to send through.

.PARAMETER Subject
    Email subject. Defaults to a reboot-maintenance notice, matching this
    script's original purpose; override for other notifications.

.PARAMETER Body
    Email body text.

.PARAMETER Priority
    Message priority: Low, Normal, or High.

.PARAMETER LogPath
    Path to the log file. Defaults to a timestamped file next to this script.

.EXAMPLE
    .\Sendmail.ps1 -From 'srv01@domain.com' -To 'ops@domain.com' -SmtpServer smtp.domain.com

.EXAMPLE
    # As a Task Scheduler action (see SystemRebootTask_and_Email.ps1):
    powershell.exe -File C:\scripts\Sendmail.ps1 -From "srv01@domain.com" -To "ops@domain.com" -SmtpServer "smtp.domain.com"

.NOTES
    Created by Ryan Cashier 05.2016 v1.0. Hardened v2.0: parameterized,
    added logging and error handling.

    -From/-To/-SmtpServer have no safe default, but this script is designed
    to run unattended with zero arguments from Task Scheduler - a Mandatory
    parameter would prompt and hang forever with no one there to answer it.
    Instead they default to this script's original placeholder values; either
    override them (recommended - pass real values via the scheduled task
    action's argument string, as in the example above) or edit the defaults
    below before deploying.

    Requires network access to the SMTP server on whatever port it expects
    (25/465/587 depending on configuration) and, if the relay requires
    authentication, credentials configured separately (Send-MailMessage's
    -Credential is not exposed here since this script is meant to run
    unattended; add it if your relay needs it).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$From = 'ServerName <ServerName@domain.com>',

    [string[]]$To = @('Whoever <whoever@domain.com>', 'Somebody <somebody@domain.com>'),

    [string]$SmtpServer = 'your.smtp.address.domain.com',

    [string]$Subject = 'Server is rebooting',

    [string]$Body = 'Server is rebooting for application maintenance',

    [ValidateSet('Low', 'Normal', 'High')]
    [string]$Priority = 'High',

    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path -Path $PSScriptRoot -ChildPath ("sendmail_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

function Write-SendmailLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $entry
}

Write-SendmailLog -Message "Starting Sendmail.ps1 (From=$From, To=$($To -join ', '), SmtpServer=$SmtpServer)"

$mailParams = @{
    From                       = $From
    To                         = $To
    Subject                    = $Subject
    Body                       = $Body
    Priority                   = $Priority
    DeliveryNotificationOption = 'OnSuccess', 'OnFailure'
    SmtpServer                 = $SmtpServer
}

if ($PSCmdlet.ShouldProcess("$($To -join ', ') via $SmtpServer", "Send mail: $Subject")) {
    try {
        Send-MailMessage @mailParams
        Write-SendmailLog -Message 'Mail sent successfully.'
    }
    catch {
        Write-SendmailLog -Message "Failed to send mail: $($_.Exception.Message)" -Level ERROR
        throw
    }
}
else {
    Write-SendmailLog -Message 'Send skipped (-WhatIf).'
}
