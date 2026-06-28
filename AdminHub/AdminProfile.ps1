<#
.SYNOPSIS
    Administrative PowerShell profile applied to all users on Windows Servers.
    Presents an interactive menu of common administrative tasks on shell startup.
    Loads in both standard and elevated sessions; tasks that need elevation can
    relaunch as Administrator from the menu ([R]).
.NOTES
    Execution policy: this script is not digitally signed. If PowerShell blocks
    it (or Deploy-AdminProfile.ps1) with "running scripts is disabled on this
    system", the execution policy must be relaxed once (per machine) from an
    elevated prompt. This only needs to be done if it has not been enabled
    before:

        Set-ExecutionPolicy RemoteSigned

    RemoteSigned allows locally-created scripts to run while still requiring
    downloaded scripts to be signed. Check the current value with
    Get-ExecutionPolicy.

    Code signing: for production, digitally sign this script (and the deploy /
    remove scripts) with an Authenticode code-signing certificate so it runs
    under the AllSigned policy. Sign LAST - any later edit breaks the signature.
    See the "Code signing" section of README.md for full instructions.

    Non-interactive use: dot-sourced as a profile it shows the menu, but it can
    also be run as a script for monitoring:
        powershell -NoProfile -File AdminProfile.ps1 -RunCheck            # text + exit code
        powershell -NoProfile -File AdminProfile.ps1 -RunCheck -AsJson    # JSON for Nagios/Zabbix/Prometheus
        powershell -NoProfile -File AdminProfile.ps1 -RunCheck -Quiet     # exit code only
    Exit codes follow the Nagios convention: 0=OK, 1=WARN, 2=FAIL(CRITICAL), 3=UNKNOWN.
#>

param(
    [switch]$RunCheck,   # run the health check non-interactively, then exit with a status code
    [switch]$AsJson,     # with -RunCheck: emit one JSON object instead of the colored text summary
    [switch]$Quiet       # with -RunCheck: suppress the summary text (exit code only)
)

# ===========================================================================
#  CONFIG - Banner
#  Printed once at startup above the menu. To rebrand, replace $BannerLines /
#  $BannerSubtitle. Generate new ASCII art at https://patorjk.com (Standard).
# ===========================================================================
$BannerLines = @'
     _       _           _       _   _       _
    / \   __| |_ __ ___ (_)_ __ | | | |_   _| |__
   / _ \ / _` | '_ ` _ \| | '_ \| |_| | | | | '_ \
  / ___ \ (_| | | | | | | | | | |  _  | |_| | |_) |
 /_/   \_\__,_|_| |_| |_|_|_| |_|_| |_|\__,_|_.__/
'@ -split '\r?\n'
$BannerColor    = 'Cyan'
$BannerSubtitle = 'Server Administration Console'

function Show-Banner {
    Write-Host ""
    foreach ($line in $BannerLines) {
        Write-Host $line -ForegroundColor $BannerColor
    }
    Write-Host "  $BannerSubtitle" -ForegroundColor DarkGray
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-RelaunchAsAdmin {
    if (Test-IsAdmin) {
        Write-Host "  Already running as Administrator." -ForegroundColor Green
        return
    }
    $exe = (Get-Process -Id $PID).Path   # current host: powershell.exe or pwsh.exe
    try {
        Start-Process -FilePath $exe -Verb RunAs -ErrorAction Stop
        Write-Host "  Opening an elevated window - approve the UAC prompt." -ForegroundColor Cyan
    } catch {
        Write-Host "  Elevation cancelled or failed: $_" -ForegroundColor Yellow
    }
}

function prompt {
    $user   = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $host_  = $env:COMPUTERNAME
    $path   = (Get-Location).Path
    if (Test-IsAdmin) {
        Write-Host "[ADMIN] " -ForegroundColor Red -NoNewline
    } else {
        Write-Host "[USER] "  -ForegroundColor DarkGray -NoNewline
    }
    Write-Host "$user" -ForegroundColor Yellow -NoNewline
    Write-Host "@$host_" -ForegroundColor Cyan -NoNewline
    Write-Host " $path" -ForegroundColor White -NoNewline
    return "`n> "
}

function Write-Header {
    param([string]$Title)
    $line = "=" * 60
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$line" -ForegroundColor DarkCyan
}

function Test-IsVirtual {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $sig = "$($cs.Manufacturer) $($cs.Model)"
    return ($sig -match 'VMware|Virtual|KVM|Xen|QEMU|Hyper-V|VirtualBox|Bochs|Parallels|Amazon|Google')
}

function Test-IsDell {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    return ($cs.Manufacturer -match 'Dell')
}

function Get-RacadmPath {
    # Local racadm, installed with Dell iDRAC Tools. Checked on PATH first.
    $cmd = Get-Command racadm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        "$env:ProgramFiles\Dell\SysMgt\iDRACTools\racadm\racadm.exe",
        "$env:ProgramFiles\Dell\SysMgt\idrac\racadm.exe",
        "${env:ProgramFiles(x86)}\Dell\SysMgt\iDRACTools\racadm\racadm.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Get-DellStorageHealth {
    # Best-effort parse of local racadm storage output. Captures raw output too,
    # since iDRAC property names vary slightly by firmware.
    # NOTE: the 'racadm storage' command set requires PowerEdge 12th generation
    # (R720-era, iDRAC7 fw 1.30.30+) or newer; older iDRAC has no 'storage'
    # subcommand and is reported as unsupported rather than failed.
    $racadm = Get-RacadmPath
    if (-not $racadm) { return $null }

    $pdisks = & $racadm storage get pdisks -o 2>&1
    $vdisks = & $racadm storage get vdisks -o 2>&1
    $raw    = (@('# pdisks') + $pdisks + @('', '# vdisks') + $vdisks) -join "`n"

    if ($raw -match 'not a valid|Invalid subcommand|not supported|UnableToFind|ERROR:') {
        return [PSCustomObject]@{ Status = 'WARN'
            Detail = 'racadm storage not supported (needs 12th gen / iDRAC7 1.30.30+)'; Raw = $raw }
    }
    if (-not $pdisks) {
        return [PSCustomObject]@{ Status = 'WARN'; Detail = 'racadm returned no data'; Raw = $raw }
    }

    $bad = @()
    $current = '(disk)'
    foreach ($line in @($pdisks) + @($vdisks)) {
        if ($line -match '^(Disk\.|PhysicalDisk|Bay|Virtual)') { $current = ($line -split '\s')[0].Trim() }
        if ($line -match 'Status\s*=\s*(.+?)\s*$' -and $Matches[1] -notmatch '^(Ok|Online|Good)$') {
            $bad += "$current Status=$($Matches[1].Trim())"
        }
        if ($line -match 'PredictiveFailureState\s*=\s*(.+?)\s*$' -and $Matches[1] -notmatch '^(Inactive|Unknown)\s*$') {
            $bad += "$current PredictiveFailure=$($Matches[1].Trim())"
        }
    }

    if ($bad.Count -gt 0) {
        return [PSCustomObject]@{ Status = 'FAIL'; Detail = ($bad -join '; '); Raw = $raw }
    }
    return [PSCustomObject]@{ Status = 'OK'; Detail = 'all physical/virtual disks Ok'; Raw = $raw }
}

function Get-TopFilesOnDrive {
    # Streaming top-N largest files under $Root. Keeps only $Top items in memory
    # (not the whole tree) and skips inaccessible paths. Reparse-point files are
    # filtered to avoid counting junction/symlink targets twice.
    param([string]$Root, [int]$Top = 5)
    $list = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
            if ($list.Count -lt $Top) {
                $list.Add($_)
            } else {
                $min = $list[0]
                foreach ($x in $list) { if ($x.Length -lt $min.Length) { $min = $x } }
                if ($_.Length -gt $min.Length) { [void]$list.Remove($min); $list.Add($_) }
            }
        }
    $list | Sort-Object Length -Descending |
        Select-Object @{N='Size(MB)'; E={[math]::Round($_.Length / 1MB, 2)}}, FullName
}

function Get-DiskSpace {
    param([switch]$IncludeTopFiles, [int]$Top = 5)
    Write-Header "Disk Space"
    Get-PSDrive -PSProvider FileSystem |
        Select-Object Name,
            @{N='Used(GB)';  E={[math]::Round($_.Used/1GB,2)}},
            @{N='Free(GB)';  E={[math]::Round($_.Free/1GB,2)}},
            @{N='Total(GB)'; E={[math]::Round(($_.Used+$_.Free)/1GB,2)}} |
        Format-Table -AutoSize

    if ($IncludeTopFiles) {
        $ans = Read-Host "`n  Scan drives for the $Top largest files? Can be slow on large volumes [Y/N]"
        if ($ans -notmatch '^[Yy]') {
            Write-Host "  Skipped largest-file scan." -ForegroundColor Yellow
            return
        }
        # Only scan fixed local disks (DriveType 3) - never network/removable.
        $fixed = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
        foreach ($d in $fixed) {
            $root = "$($d.DeviceID)\"
            Write-Host "`n  Top $Top largest files on $($d.DeviceID) (scanning, may take a while on large drives)..." -ForegroundColor DarkGray
            $files = Get-TopFilesOnDrive -Root $root -Top $Top
            if ($files) { $files | Format-Table 'Size(MB)', FullName -AutoSize }
            else { Write-Host "    (no files found or access denied)" -ForegroundColor DarkGray }
        }
    }
}

function Get-TopResourceUsers {
    param([int]$Seconds = 5, [int]$Top = 10)
    Write-Header "Top Resource Users (CPU sampled over ${Seconds}s)"

    $cores = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).NumberOfLogicalProcessors
    if (-not $cores) { $cores = 1 }

    # --- Top CPU: average live samples for an accurate 'now' reading ---
    Write-Host "  Sampling CPU..." -ForegroundColor DarkGray
    $samples = Get-Counter '\Process(*)\% Processor Time' -SampleInterval 1 -MaxSamples $Seconds -ErrorAction SilentlyContinue

    if ($samples) {
        $cpu = @{}
        foreach ($s in $samples.CounterSamples) {
            $n = $s.InstanceName
            if ($n -eq '_total' -or $n -eq 'idle') { continue }
            if (-not $cpu.ContainsKey($n)) { $cpu[$n] = [System.Collections.ArrayList]@() }
            [void]$cpu[$n].Add($s.CookedValue)
        }
        Write-Header "Top $Top by CPU (% of total CPU)"
        $cpu.GetEnumerator() | ForEach-Object {
            [PSCustomObject]@{
                Name   = $_.Key
                'CPU%' = [math]::Round((($_.Value | Measure-Object -Average).Average / $cores), 1)
            }
        } | Sort-Object 'CPU%' -Descending | Select-Object -First $Top | Format-Table -AutoSize
    } else {
        Write-Host "  Live sampling unavailable; falling back to cumulative CPU time." -ForegroundColor Yellow
        Get-Process | Sort-Object CPU -Descending | Select-Object -First $Top Name, Id,
            @{N='CPU(s)'; E={[math]::Round($_.CPU,2)}} | Format-Table -AutoSize
    }

    # --- Top memory: current working set ---
    Write-Header "Top $Top by Memory (working set)"
    Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First $Top Name, Id,
        @{N='Mem(MB)';       E={[math]::Round($_.WorkingSet / 1MB, 2)}},
        @{N='PrivateMem(MB)';E={[math]::Round($_.PrivateMemorySize64 / 1MB, 2)}} |
        Format-Table -AutoSize
}

function Test-ProcessIsCritical {
    # Returns $true if Windows marks the process as critical (terminating it
    # bugchecks the OS). Best-effort P/Invoke; returns $false if it can't tell.
    param([int]$ProcessId)
    try {
        if (-not ('AdminHub.ProcCheck' -as [type])) {
            Add-Type -Namespace 'AdminHub' -Name 'ProcCheck' -ErrorAction Stop -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool IsProcessCritical(System.IntPtr hProcess, out bool Critical);
'@
        }
        $h = (Get-Process -Id $ProcessId -ErrorAction Stop).Handle
        $crit = $false
        if ([AdminHub.ProcCheck]::IsProcessCritical($h, [ref]$crit)) { return [bool]$crit }
    } catch { }
    return $false
}

function Restart-ServiceByName {
    $name = Read-Host "  Enter service name or display name"
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }

    # Resolve by EXACT service name first, then exact display name (literal, so a
    # typed '*' or '[' is not treated as a wildcard).
    $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $name })
    if (-not $svc) { $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name }) }
    if (-not $svc) { Write-Host "  Service '$name' not found (use the exact service or display name)." -ForegroundColor Red; return }
    if ($svc.Count -gt 1) {
        Write-Host "  Multiple services match - be more specific:" -ForegroundColor Yellow
        $svc | Format-Table Name, DisplayName, Status -AutoSize
        return
    }
    $svc = $svc[0]

    # Kernel-critical services - killing their host process bugchecks the box.
    $criticalSvcs = @('DcomLaunch','RpcSs','RpcEptMapper','Power','PlugPlay','BrokerInfrastructure',
                      'LSM','SamSs','Schedule','EventLog','CoreMessagingRegistrar','SystemEventsBroker',
                      'Dhcp','Dnscache','nsi','gpsvc','ProfSvc')

    $wqlName = $svc.Name.Replace("'", "''")   # escape for WQL filter
    $cim = Get-CimInstance Win32_Service -Filter "Name='$wqlName'" -ErrorAction SilentlyContinue
    $procId = if ($cim -and $cim.ProcessId) { [int]($cim.ProcessId | Select-Object -First 1) } else { 0 }

    Write-Header "Service: $($svc.DisplayName)"
    Write-Host ("  Name      : {0}" -f $svc.Name)
    Write-Host ("  Status    : {0}" -f $svc.Status)
    if ($cim) { Write-Host ("  StartType : {0}" -f $cim.StartMode) }

    # Running dependents - a restart (-Force) also stops/restarts these.
    $deps = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' })
    if ($deps.Count -gt 0) {
        Write-Host ("  Dependents: {0} running - restart also bounces: {1}" -f `
            $deps.Count, (($deps | Select-Object -First 8 -ExpandProperty Name) -join ', ')) -ForegroundColor Yellow
    }

    $siblings = @()
    if ($procId -gt 0) {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        Write-Host ("  PID       : {0} ({1})" -f $procId, $(if ($p) { $p.ProcessName } else { 'unknown' }))
        $siblings = @(Get-CimInstance Win32_Service -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $svc.Name })
        if ($siblings.Count -gt 0) {
            Write-Host ("  SHARED PID: also hosts {0} other service(s): {1}" -f `
                $siblings.Count, (($siblings | Select-Object -First 8 -ExpandProperty Name) -join ', ')) -ForegroundColor Yellow
            Write-Host "  Killing this process stops ALL of them." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  PID       : (service not running)"
    }

    if (-not (Test-IsAdmin)) {
        Write-Host "  Note: restart/kill need admin - use [R] at the menu to elevate." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  [R] Restart    [K] Kill process (force)    [C] Cancel" -ForegroundColor DarkGray
    $action = Read-Host "  Choose"

    switch -Regex ($action) {
        '^[Rr]' {
            try {
                Restart-Service -Name $svc.Name -Force -ErrorAction Stop
                Write-Host "  '$($svc.Name)' restarted." -ForegroundColor Green
            } catch { Write-Host "  Restart failed: $($_.Exception.Message)" -ForegroundColor Red }
        }
        '^[Kk]' {
            if ($procId -le 0) { Write-Host "  Service is not running - nothing to kill." -ForegroundColor Yellow; return }

            # Guard 1: refuse if the target or any co-hosted service is kernel-critical.
            $hosted = @($svc.Name) + @($siblings | Select-Object -ExpandProperty Name)
            $hit = @($hosted | Where-Object { $criticalSvcs -contains $_ })
            if ($hit.Count -gt 0) {
                Write-Host ("  Refusing to kill PID {0}: hosts kernel-critical service(s) [{1}] - killing it would crash the OS." -f `
                    $procId, ($hit -join ', ')) -ForegroundColor Red
                Write-Host "  Use [R] Restart instead." -ForegroundColor DarkGray
                return
            }
            # Guard 2: refuse if Windows itself flags the process as critical.
            if (Test-ProcessIsCritical -ProcessId $procId) {
                Write-Host "  Refusing to kill PID ${procId}: Windows marks it CRITICAL (terminating it bugchecks the OS)." -ForegroundColor Red
                return
            }
            # Guard 3: re-validate the PID still belongs to this service (PID-reuse race).
            $cimNow = Get-CimInstance Win32_Service -Filter "Name='$wqlName'" -ErrorAction SilentlyContinue
            $pidNow = if ($cimNow -and $cimNow.ProcessId) { [int]($cimNow.ProcessId | Select-Object -First 1) } else { 0 }
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $proc -or $pidNow -ne $procId) {
                Write-Host "  PID changed since it was read (service stopped/restarted). Aborting - re-run the option." -ForegroundColor Yellow
                return
            }

            $warn = if ($siblings.Count -gt 0) { " and $($siblings.Count) co-hosted service(s)" } else { "" }
            $confirm = Read-Host "  Force-kill PID $procId ($($proc.ProcessName))$warn? Abrupt - unsaved state is lost. [Y/N]"
            if ($confirm -notmatch '^[Yy]') { Write-Host "  Cancelled." -ForegroundColor Yellow; return }

            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Write-Host "  Killed PID $procId." -ForegroundColor Green
            } catch { Write-Host "  Kill failed: $($_.Exception.Message)" -ForegroundColor Red; return }

            $start = Read-Host "  Start the killed service(s) again now? [Y/N]"
            if ($start -match '^[Yy]') {
                foreach ($sn in $hosted) {
                    $so = Get-Service -Name $sn -ErrorAction SilentlyContinue
                    if ($so) { try { $so.WaitForStatus('Stopped', '00:00:10') } catch { } }
                    try { Start-Service -Name $sn -ErrorAction Stop; Write-Host "  Started $sn." -ForegroundColor Green }
                    catch { Write-Host "  Start $sn failed: $($_.Exception.Message)" -ForegroundColor Red }
                }
            }
        }
        default { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    }

    Start-Sleep -Milliseconds 600
    $after = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
    $cim2 = Get-CimInstance Win32_Service -Filter "Name='$wqlName'" -ErrorAction SilentlyContinue
    if ($after) {
        $newPid = if ($cim2 -and $cim2.ProcessId) { $cim2.ProcessId } else { '-' }
        Write-Host ("  Now: {0}  (PID {1})" -f $after.Status, $newPid) -ForegroundColor Cyan
    }
}

function Test-PendingReboot {
    $reasons = @()

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'Component-Based Servicing'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update'
    }
    $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfro) { $reasons += 'Pending file rename' }

    $cn  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
                -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $pcn = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
                -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($cn -and $pcn -and ($cn -ne $pcn)) { $reasons += 'Pending computer rename' }

    return $reasons
}

function Get-PendingUpdates {
    Write-Header "Pending Windows Updates"
    if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
        Write-Host "  PSWindowsUpdate module not found. Install with: Install-Module PSWindowsUpdate" -ForegroundColor Yellow
    } else {
        Import-Module PSWindowsUpdate
        Get-WindowsUpdate | Select-Object KB, Title, Size, MsrcSeverity | Format-Table -AutoSize
    }

    Write-Host ""
    $rebootReasons = Test-PendingReboot
    if ($rebootReasons.Count -gt 0) {
        Write-Host "  REBOOT PENDING - $($rebootReasons -join ', ')" -ForegroundColor Red
    } else {
        Write-Host "  No reboot pending." -ForegroundColor Green
    }
}

function Get-TopMemory {
    Write-Header "Top 10 Processes by Memory Usage"
    Get-Process |
        Sort-Object WorkingSet -Descending |
        Select-Object -First 10 Name, Id,
            @{N='Mem(MB)';       E={[math]::Round($_.WorkingSet / 1MB, 2)}},
            @{N='PrivateMem(MB)';E={[math]::Round($_.PrivateMemorySize64 / 1MB, 2)}},
            @{N='Handles';       E={$_.HandleCount}} |
        Format-Table -AutoSize
}

function Get-SwapUsage {
    Write-Header "Top 10 Processes by Page File (Swap) Usage"
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($pf) {
        foreach ($p in $pf) {
            $pct = if ($p.AllocatedBaseSize -gt 0) {
                [math]::Round($p.CurrentUsage / $p.AllocatedBaseSize * 100, 1)
            } else { 0 }
            Write-Host ("  Pagefile: {0}  Used: {1} MB / {2} MB  ({3}%)" -f `
                $p.Name, $p.CurrentUsage, $p.AllocatedBaseSize, $pct) -ForegroundColor $(
                    if ($pct -ge 80) { 'Red' } elseif ($pct -ge 60) { 'Yellow' } else { 'Green' }
                )
        }
        Write-Host ""
    }
    Get-Process |
        Sort-Object PagedMemorySize64 -Descending |
        Select-Object -First 10 Name, Id,
            @{N='PagedMem(MB)';   E={[math]::Round($_.PagedMemorySize64 / 1MB, 2)}},
            @{N='VirtualMem(MB)'; E={[math]::Round($_.VirtualMemorySize64 / 1MB, 2)}},
            @{N='NonPagedMem(MB)';E={[math]::Round($_.NonpagedSystemMemorySize64 / 1MB, 2)}} |
        Format-Table -AutoSize
}

function Get-ActiveSessions {
    Write-Header "Active User Sessions"
    $raw = query session 2>$null
    if (-not $raw) {
        Write-Host "  No session data available." -ForegroundColor Yellow
        return
    }
    $raw | Select-Object -Skip 1 | ForEach-Object {
        if ($_ -match '^\s*(\S+)\s+(\S+)\s+(\d+)\s+(\S+)') {
            [PSCustomObject]@{
                SessionName = $Matches[1]
                Username    = $Matches[2]
                ID          = $Matches[3]
                State       = $Matches[4]
            }
        }
    } | Format-Table -AutoSize
}

function Show-LogTail {
    Write-Header "Tail a Log File"

    # Quick-pick of common server logs - only those that exist on this box are shown.
    $common = @(
        @{ Label = 'CBS (Windows servicing)';   Path = "$env:SystemRoot\Logs\CBS\CBS.log" },
        @{ Label = 'DISM';                       Path = "$env:SystemRoot\Logs\DISM\dism.log" },
        @{ Label = 'IIS logs (newest)';          Path = "$env:SystemDrive\inetpub\logs\LogFiles" },
        @{ Label = 'System32 LogFiles';          Path = "$env:SystemRoot\System32\LogFiles" },
        @{ Label = 'Windows setup (Panther)';    Path = "$env:SystemRoot\Panther\setupact.log" },
        @{ Label = 'AdminHub health reports';    Path = "$env:SystemDrive\AdminReports" }
    )
    $avail = @($common | Where-Object { Test-Path $_.Path })

    $path = $null
    if ($avail.Count -gt 0) {
        Write-Host "  Quick pick a common log, or enter a path:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $avail.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f ($i + 1), $avail[$i].Label) -ForegroundColor Green
            Write-Host ("        {0}" -f $avail[$i].Path) -ForegroundColor DarkGray
        }
        Write-Host "    [P] Enter a custom path" -ForegroundColor Green
        $sel = Read-Host "  Select a number, P, or paste a path"
        if ([string]::IsNullOrWhiteSpace($sel)) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $avail.Count) {
            $path = $avail[[int]$sel - 1].Path
        } elseif ($sel -match '^[Pp]$') {
            $path = Read-Host "  Log file, directory, or wildcard"
        } else {
            $path = $sel   # treat anything else as a path typed directly
        }
    } else {
        $path = Read-Host "  Log file, directory, or wildcard (e.g. C:\inetpub\logs\LogFiles\W3SVC1\*.log)"
    }
    if ([string]::IsNullOrWhiteSpace($path)) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }

    # Resolve to a single file: exact file, newest file in a directory, or newest wildcard match.
    $file = $null
    $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($item -and $item.PSIsContainer) {
        $file = Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($file) { Write-Host "  Directory given - tailing newest file: $($file.Name)" -ForegroundColor DarkGray }
    } elseif ($item) {
        $file = $item
    } else {
        $hits = @(Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($hits.Count -gt 1) { Write-Host "  $($hits.Count) files match - tailing newest: $($hits[0].Name)" -ForegroundColor DarkGray }
        $file = $hits | Select-Object -First 1
    }
    if (-not $file) { Write-Host "  No file found for '$path'." -ForegroundColor Red; return }

    $nIn = Read-Host "  How many lines? [default 20]"
    $n = if ($nIn -match '^\d+$') { [int]$nIn } else { 20 }
    $follow = (Read-Host "  Follow live, like tail -f? [Y/N]") -match '^[Yy]'

    Write-Host ""
    Write-Host ("  --- {0}  (last {1} lines{2}) ---" -f $file.FullName, $n,
        $(if ($follow) { '; following - press Ctrl+C to stop' } else { '' })) -ForegroundColor Cyan
    try {
        if ($follow) {
            Write-Host "  (Ctrl+C returns to the shell; type Show-AdminMenu to reopen the menu)" -ForegroundColor DarkGray
            Get-Content -LiteralPath $file.FullName -Tail $n -Wait -ErrorAction Stop
        } else {
            Get-Content -LiteralPath $file.FullName -Tail $n -ErrorAction Stop
        }
    } catch {
        Write-Host "  Error reading log: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-RecentSystemErrors {
    # Critical (1) + Error (2) events from the System log in the last $Hours hours.
    # Uses Get-WinEvent so it works in both Windows PowerShell 5.1 and PowerShell 7
    # (Get-EventLog does not exist in 7). Get-WinEvent throws when nothing matches,
    # so a zero-match result is caught and returned as an empty array.
    param([int]$Hours = 24, [int]$Max = 50)
    $since = (Get-Date).AddHours(-$Hours)
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } `
            -MaxEvents $Max -ErrorAction Stop
    } catch {
        @()
    }
}

function Show-RecentSystemErrors {
    param([int]$Hours = 24, [int]$Max = 20)
    Write-Header "Recent System Errors (last ${Hours}h)"
    $events = Get-RecentSystemErrors -Hours $Hours -Max $Max
    if (-not $events) {
        Write-Host "  No error or critical events in the last $Hours hours." -ForegroundColor Green
        return
    }
    $events | Select-Object `
        @{N='Time';    E={ $_.TimeCreated.ToString('MM-dd HH:mm') }},
        @{N='Level';   E={ $_.LevelDisplayName }},
        @{N='Source';  E={ $_.ProviderName }},
        @{N='ID';      E={ $_.Id }},
        @{N='Message'; E={ ($_.Message -split "`r?`n")[0] }} |
        Format-Table -AutoSize -Wrap
    Write-Host "  Showing up to $Max most recent (Critical + Error)." -ForegroundColor DarkGray
}

function Get-NetworkAdapterHealth {
    # Connected (Up) adapters with link speed and CUMULATIVE discard/error counters
    # (totals since the adapter came up, not a rate). Requires the NetAdapter module
    # (Windows 8 / Server 2012+); returns $null if it is unavailable.
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) { return $null }
    $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    foreach ($a in $up) {
        $s = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name        = $a.Name
            LinkSpeed   = $a.LinkSpeed
            RxDiscarded = if ($s) { [int64]$s.ReceivedDiscardedPackets } else { 0 }
            RxErrors    = if ($s) { [int64]$s.ReceivedPacketErrors }     else { 0 }
            TxDiscarded = if ($s) { [int64]$s.OutboundDiscardedPackets } else { 0 }
            TxErrors    = if ($s) { [int64]$s.OutboundPacketErrors }     else { 0 }
        }
    }
}

function Show-NetworkStatus {
    Write-Header "Network Adapters"
    $nics = Get-NetworkAdapterHealth
    if ($null -eq $nics) {
        Write-Host "  Get-NetAdapter is not available on this system." -ForegroundColor Yellow
    } elseif (-not $nics) {
        Write-Host "  No connected (Up) network adapters." -ForegroundColor Yellow
    } else {
        $nics | Format-Table Name, LinkSpeed, RxDiscarded, RxErrors, TxDiscarded, TxErrors -AutoSize
        $bad = $nics | Where-Object { ($_.RxDiscarded + $_.RxErrors + $_.TxDiscarded + $_.TxErrors) -gt 0 }
        if ($bad) {
            Write-Host ("  Discards/errors on: " + (($bad | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor Yellow
            Write-Host "  (Counters are cumulative since boot; a few discards are usually benign.)" -ForegroundColor DarkGray
        } else {
            Write-Host "  No discards or errors on any connected adapter." -ForegroundColor Green
        }
    }
    Show-GatewayHealth
    Show-NicTeaming
    Show-DnsHealth
    Show-NetworkLocation
}

function Get-NicTeamingHealth {
    # Windows NIC teaming (LBFO). Returns $null if the LBFO cmdlets are absent,
    # an empty array if no teams exist, else one object per team with member and
    # active-member counts so a degraded team (only one adapter passing traffic)
    # can be flagged.
    if (-not (Get-Command Get-NetLbfoTeam -ErrorAction SilentlyContinue)) { return $null }
    $teams = @()
    try { $teams = @(Get-NetLbfoTeam -ErrorAction Stop) } catch { return $null }
    foreach ($t in $teams) {
        $members = @()
        try { $members = @(Get-NetLbfoTeamMember -Team $t.Name -ErrorAction Stop) } catch {}
        $active = @($members | Where-Object { $_.OperationalStatus -eq 'Active' })
        $failed = @($members | Where-Object { $_.OperationalStatus -notin @('Active','Standby') })
        [PSCustomObject]@{
            Team          = $t.Name
            Mode          = $t.TeamingMode
            LB            = $t.LoadBalancingAlgorithm
            Status        = $t.Status
            Members       = $members.Count
            Active        = $active.Count
            FailedMembers = (($failed | ForEach-Object { "$($_.Name)=$($_.OperationalStatus)" }) -join ', ')
        }
    }
}

function Show-NicTeaming {
    Write-Header "NIC Teaming"
    $teams = Get-NicTeamingHealth
    if ($null -eq $teams) { Write-Host "  NIC teaming (LBFO) not available on this system." -ForegroundColor DarkGray; return }
    if (-not $teams)      { Write-Host "  No NIC teams configured." -ForegroundColor DarkGray; return }
    $teams | Format-Table Team, Mode, LB, Status, Members, Active, FailedMembers -AutoSize
    $deg = @($teams | Where-Object { $_.Status -ne 'Up' -or $_.Active -lt $_.Members -or $_.FailedMembers })
    if ($deg) {
        foreach ($d in $deg) {
            Write-Host ("  WARN: team '{0}' degraded - {1}/{2} active{3}" -f `
                $d.Team, $d.Active, $d.Members, $(if ($d.FailedMembers) { "; $($d.FailedMembers)" })) -ForegroundColor Yellow
        }
    } else {
        Write-Host "  All teams healthy." -ForegroundColor Green
    }
}

function Get-DnsHealth {
    # Configured DNS servers, plus a resolution test against the AD domain when
    # domain-joined (Resolved stays $null when not joined, so it is not flagged).
    $servers = @()
    try {
        $servers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object ServerAddresses | ForEach-Object { $_.ServerAddresses }) | Select-Object -Unique
    } catch {}
    $r = [PSCustomObject]@{ Servers = ($servers -join ', '); Target = $null; Resolved = $null; Addresses = $null; Error = $null }
    if (-not $env:USERDNSDOMAIN) { return $r }
    $r.Target = $env:USERDNSDOMAIN
    try {
        $ans = Resolve-DnsName -Name $r.Target -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        $ips = @($ans | Where-Object IPAddress | ForEach-Object { $_.IPAddress })
        $r.Resolved  = ($ips.Count -gt 0)
        $r.Addresses = ($ips -join ', ')
    } catch { $r.Resolved = $false; $r.Error = $_.Exception.Message }
    return $r
}

function Show-DnsHealth {
    Write-Header "DNS"
    $d = Get-DnsHealth
    Write-Host "  Servers: $(if ($d.Servers) { $d.Servers } else { '(none configured)' })" -ForegroundColor Gray
    if ($null -eq $d.Resolved) {
        Write-Host "  Resolution test skipped (not domain-joined)." -ForegroundColor DarkGray
    } elseif ($d.Resolved) {
        Write-Host "  Resolved $($d.Target) -> $($d.Addresses)" -ForegroundColor Green
    } else {
        Write-Host "  FAILED to resolve $($d.Target): $($d.Error)" -ForegroundColor Red
    }
}

function Get-NetworkLocationHealth {
    # Network Location Awareness (NlaSvc) + Network List Service (netprofm) and the
    # resulting connection-profile category. If NLA misclassifies the network as
    # 'Public', the Public Windows Firewall profile applies and typically BLOCKS
    # inbound ICMP/ping - so monitoring (e.g. Nagios) sees the host as down and
    # other devices cannot ping it. FAIL if NlaSvc is not running; WARN if a
    # profile is Public or netprofm is stopped.
    $nla      = Get-Service -Name NlaSvc   -ErrorAction SilentlyContinue
    $netprofm = Get-Service -Name netprofm -ErrorAction SilentlyContinue
    $cats = @()
    if (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
        try { $cats = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { $_.NetworkCategory }) } catch { }
    }
    $public = @($cats | Where-Object { $_ -eq 'Public' })

    $status = 'OK'
    $parts  = @()
    if (-not $nla) {
        $parts += 'NlaSvc not found'
    } elseif ($nla.Status -ne 'Running') {
        $status = 'FAIL'; $parts += "NlaSvc $($nla.Status)"
    } else {
        $parts += 'NlaSvc running'
    }
    if ($netprofm -and $netprofm.Status -ne 'Running') {
        if ($status -ne 'FAIL') { $status = 'WARN' }
        $parts += "netprofm $($netprofm.Status)"
    }
    if ($cats.Count -gt 0) {
        $parts += ('profile: ' + ($cats -join ', '))
        if ($public.Count -gt 0) {
            if ($status -eq 'OK') { $status = 'WARN' }
            $parts += 'Public profile may block inbound ping'
        }
    }
    [PSCustomObject]@{ Status = $status; Detail = ($parts -join '; '); Categories = ($cats -join ', ') }
}

function Show-NetworkLocation {
    Write-Header "Network Location (NLA)"
    $n = Get-NetworkLocationHealth
    $color = switch ($n.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host "  [$($n.Status)] $($n.Detail)" -ForegroundColor $color
    if ($n.Status -ne 'OK') {
        Write-Host "  Fix: restart Network Location Awareness (NlaSvc) via [3], or correct the firewall profile -" -ForegroundColor DarkGray
        Write-Host "  a Public profile blocks inbound ICMP so remote pings / Nagios checks fail." -ForegroundColor DarkGray
    }
}

function Get-HardwareHealth {
    # Physical-only temperature / power-supply health. Returns $null on VMs.
    # Dell servers use racadm getsensorinfo (best-effort parse + raw capture);
    # otherwise tries ACPI thermal zones. Reports 'INFO' when no source exists.
    if (Test-IsVirtual) { return $null }
    if ((Test-IsDell) -and (Get-RacadmPath)) {
        $racadm = Get-RacadmPath
        $raw = & $racadm getsensorinfo 2>&1
        $text = ($raw | Out-String)
        $failLines = @($raw | Where-Object { $_ -match '(?i)(critical|failed|non-recoverable|lost)' })
        $warnLines = @($raw | Where-Object { $_ -match '(?i)\bwarning\b' })
        $status = if ($failLines) { 'FAIL' } elseif ($warnLines) { 'WARN' } else { 'OK' }
        $detail = if ($failLines) { (($failLines | Select-Object -First 4) -join '; ').Trim() }
                  elseif ($warnLines) { (($warnLines | Select-Object -First 4) -join '; ').Trim() }
                  else { 'all temperature/power sensors Ok' }
        return [PSCustomObject]@{ Source = 'Dell racadm'; Status = $status; Detail = $detail; Raw = $text }
    }
    try {
        $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        if ($tz) {
            $temps = @($tz | ForEach-Object { [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1) })
            $max = ($temps | Measure-Object -Maximum).Maximum
            $status = if ($max -ge 90) { 'FAIL' } elseif ($max -ge 80) { 'WARN' } else { 'OK' }
            return [PSCustomObject]@{ Source = 'ACPI thermal'; Status = $status; Detail = "max zone temp ${max}C"; Raw = ($temps -join ', ') }
        }
    } catch {}
    return [PSCustomObject]@{ Source = 'none'; Status = 'INFO'; Detail = 'no temperature/PSU sensor source (vendor tools required)'; Raw = '' }
}

function Show-HardwareHealth {
    Write-Header "Hardware (temperature / power)"
    $hw = Get-HardwareHealth
    if ($null -eq $hw) { Write-Host "  Skipped (virtual machine)." -ForegroundColor DarkGray; return }
    $color = switch ($hw.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host "  [$($hw.Status)] $($hw.Detail)  (source: $($hw.Source))" -ForegroundColor $color
    if ($hw.Status -eq 'FAIL') {
        Write-Host "  Run 'racadm getsensorinfo' (or your vendor CLI) for full sensor detail." -ForegroundColor DarkGray
    }
}

function Get-TimeSyncHealth {
    # Domain time drift via w32tm. Returns $null when not domain-joined.
    # WARN if |offset| >= 2s, FAIL if >= 30s (well before Kerberos' 5-min skew).
    if (-not $env:USERDNSDOMAIN) { return $null }
    $source = (w32tm /query /source 2>&1 | Select-Object -First 1)
    $status = 'WARN'; $detail = "could not measure offset (source: $source)"; $offset = $null
    try {
        $chart = w32tm /stripchart /computer:$env:USERDNSDOMAIN /samples:1 /dataonly 2>&1
        $line  = $chart | Where-Object { $_ -match '([+-]\d+\.\d+)s' } | Select-Object -Last 1
        if ($line -match '([+-]\d+\.\d+)s') {
            $offset = [double]$Matches[1]
            $abs = [math]::Abs($offset)
            $status = if ($abs -ge 30) { 'FAIL' } elseif ($abs -ge 2) { 'WARN' } else { 'OK' }
            $detail = ("offset {0}s from {1}" -f $offset, $source)
        }
    } catch { $detail = "w32tm error: $($_.Exception.Message)" }
    [PSCustomObject]@{ Source = $source; Offset = $offset; Status = $status; Detail = $detail }
}

function Show-TimeSync {
    Write-Header "Domain Time Sync"
    $t = Get-TimeSyncHealth
    if ($null -eq $t) { Write-Host "  Skipped (not domain-joined)." -ForegroundColor DarkGray; return }
    $color = switch ($t.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host "  [$($t.Status)] $($t.Detail)" -ForegroundColor $color
}

function Get-GatewayHealth {
    # Default IPv4 gateway(s) for connected adapters, each with an ICMP ping test.
    # Returns an empty array when no default gateway is configured.
    $list = @()
    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        try {
            $list = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway } |
                ForEach-Object { [PSCustomObject]@{ Interface = $_.InterfaceAlias; Gateway = $_.IPv4DefaultGateway.NextHop } })
        } catch {}
    }
    if (-not $list) {
        try {
            $list = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop |
                Where-Object { $_.DefaultIPGateway } |
                ForEach-Object { [PSCustomObject]@{ Interface = $_.Description; Gateway = $_.DefaultIPGateway[0] } })
        } catch {}
    }
    $seen = @{}
    foreach ($g in $list) {
        if (-not $g.Gateway -or $seen.ContainsKey($g.Gateway)) { continue }
        $seen[$g.Gateway] = $true
        $ok = $false
        try { $ok = [bool](Test-Connection $g.Gateway -Count 2 -Quiet -ErrorAction Stop) } catch { $ok = $false }
        [PSCustomObject]@{ Interface = $g.Interface; Gateway = $g.Gateway; Reachable = $ok }
    }
}

function Show-GatewayHealth {
    Write-Header "Default Gateway"
    $gws = Get-GatewayHealth
    if (-not $gws) { Write-Host "  No default gateway configured." -ForegroundColor DarkGray; return }
    foreach ($g in $gws) {
        if ($g.Reachable) {
            Write-Host ("  [OK]   {0} via {1} - reachable" -f $g.Gateway, $g.Interface) -ForegroundColor Green
        } else {
            Write-Host ("  [FAIL] {0} via {1} - NO RESPONSE" -f $g.Gateway, $g.Interface) -ForegroundColor Red
        }
    }
}

function Get-CpuMemoryFaults {
    # Hardware CPU/memory faults from WHEA machine-check / ECC events in the System
    # log (corrected -> WARN, uncorrected -> FAIL), plus any processor reporting a
    # non-OK status. Safe on VMs (they simply have no WHEA events).
    $whea = @()
    try {
        $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } -MaxEvents 50 -ErrorAction Stop)
    } catch {}
    $cpuBad = @()
    try {
        $cpuBad = @(Get-CimInstance Win32_Processor -ErrorAction Stop |
            Where-Object { $_.Status -and $_.Status -ne 'OK' } |
            ForEach-Object { "$($_.DeviceID)=$($_.Status)" })
    } catch {}
    $uncorrected = @($whea | Where-Object { $_.Level -in 1, 2 })
    $status = if ($uncorrected -or $cpuBad) { 'FAIL' } elseif ($whea) { 'WARN' } else { 'OK' }
    $parts = @()
    if ($whea)   { $parts += "$(@($whea).Count) WHEA event(s) ($(@($uncorrected).Count) uncorrected)" }
    if ($cpuBad) { $parts += "CPU status: $($cpuBad -join ', ')" }
    if (-not $parts) { $parts += 'no WHEA hardware errors; CPU status OK' }
    [PSCustomObject]@{
        Status = $status
        Detail = ($parts -join '; ')
        Recent = @($whea | Select-Object -First 5 | ForEach-Object { "{0} {1} (id {2})" -f $_.TimeCreated.ToString('MM-dd HH:mm'), $_.LevelDisplayName, $_.Id })
    }
}

function Show-CpuMemoryFaults {
    Write-Header "CPU / Memory Faults"
    $f = Get-CpuMemoryFaults
    $color = switch ($f.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
    Write-Host "  [$($f.Status)] $($f.Detail)" -ForegroundColor $color
    if ($f.Recent) {
        Write-Host "  Recent WHEA events:" -ForegroundColor DarkGray
        $f.Recent | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

function Get-ListeningPorts {
    # Distinct TCP + UDP listening endpoints with the owning process. Returns
    # $null if the Net*Connection cmdlets are unavailable (very old OS).
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
    $procs = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[[int]$_.Id] = $_.ProcessName }
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ Proto = 'TCP'; LocalAddress = $_.LocalAddress; Port = [int]$_.LocalPort
            ProcessId = [int]$_.OwningProcess; Process = $procs[[int]$_.OwningProcess] }
    })
    $udp = @()
    if (Get-Command Get-NetUDPEndpoint -ErrorAction SilentlyContinue) {
        $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{ Proto = 'UDP'; LocalAddress = $_.LocalAddress; Port = [int]$_.LocalPort
                ProcessId = [int]$_.OwningProcess; Process = $procs[[int]$_.OwningProcess] }
        })
    }
    @($tcp + $udp) | Sort-Object Proto, Port, Process -Unique
}

function Get-ConnectionSummary {
    # TCP connection counts grouped by state (Established, TimeWait, ...).
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return $null }
    $all = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
    $byState = @($all | Group-Object State | Sort-Object Count -Descending |
        ForEach-Object { [PSCustomObject]@{ State = $_.Name; Count = $_.Count } })
    [PSCustomObject]@{ Total = $all.Count; ByState = $byState
        Established = @($all | Where-Object { $_.State -eq 'Established' }).Count }
}

function Get-ActiveConnections {
    param([int]$Top = 15)
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return @() }
    $procs = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[[int]$_.Id] = $_.ProcessName }
    @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Sort-Object RemoteAddress | Select-Object -First $Top | ForEach-Object {
            [PSCustomObject]@{
                Local   = "$($_.LocalAddress):$($_.LocalPort)"
                Remote  = "$($_.RemoteAddress):$($_.RemotePort)"
                Process = $procs[[int]$_.OwningProcess]
            }
        })
}

function Show-PortsConnections {
    Write-Header "Listening Ports"
    $listen = Get-ListeningPorts
    if ($null -eq $listen) {
        Write-Host "  Get-NetTCPConnection not available on this system." -ForegroundColor Yellow
        return
    }
    if (-not $listen) {
        Write-Host "  No listening ports found." -ForegroundColor DarkGray
    } else {
        $listen | Format-Table Proto, LocalAddress, Port, ProcessId, Process -AutoSize
        $tcpN = @($listen | Where-Object { $_.Proto -eq 'TCP' }).Count
        $udpN = @($listen | Where-Object { $_.Proto -eq 'UDP' }).Count
        Write-Host "  $tcpN TCP + $udpN UDP listening." -ForegroundColor DarkGray
    }

    Write-Header "Active TCP Connections"
    $sum = Get-ConnectionSummary
    if ($sum) {
        foreach ($s in $sum.ByState) { Write-Host ("  {0,-12} {1}" -f $s.State, $s.Count) }
        $est = Get-ActiveConnections -Top 15
        if ($est) {
            Write-Host "`n  Established (up to 15):" -ForegroundColor Cyan
            $est | Format-Table Local, Remote, Process -AutoSize
        }
    } else {
        Write-Host "  No connection data." -ForegroundColor DarkGray
    }
}

function Get-CertHealth {
    # Server-authentication certificates in LocalMachine\My expiring soon.
    # WARN within $WarnDays, FAIL expired or within $FailDays. Internally guarded.
    param([int]$WarnDays = 30, [int]$FailDays = 7)
    try {
        $serverAuth = '1.3.6.1.5.5.7.3.1'
        $now = Get-Date
        # Server-auth EKU, or no EKU at all (X.509: a cert with no EKU is valid for any use).
        $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object {
            $_.HasPrivateKey -and
            ($_.EnhancedKeyUsageList.Count -eq 0 -or ($_.EnhancedKeyUsageList.ObjectId -contains $serverAuth))
        })
        if (-not $certs) { return [PSCustomObject]@{ Status='OK'; Detail='no server-auth certs found'; Value=$null; Items=@() } }
        $ranked = $certs | Select-Object Subject, Thumbprint, NotAfter,
            @{N='DaysLeft'; E={ [int][math]::Floor((($_.NotAfter) - $now).TotalDays) }} | Sort-Object DaysLeft
        $soonest = $ranked[0]
        $expiring = @($ranked | Where-Object { $_.DaysLeft -lt $WarnDays })
        $st = if ($soonest.DaysLeft -lt $FailDays) { 'FAIL' } elseif ($expiring.Count -gt 0) { 'WARN' } else { 'OK' }
        $detail = if ($expiring.Count -gt 0) {
            "$($expiring.Count) expiring; soonest: $($soonest.Subject) ($($soonest.DaysLeft)d)"
        } else { "$($certs.Count) server-auth cert(s), none within ${WarnDays}d (soonest $($soonest.DaysLeft)d)" }
        [PSCustomObject]@{ Status=$st; Detail=$detail; Value=$soonest.DaysLeft; Items=$ranked }
    } catch {
        [PSCustomObject]@{ Status='ERROR'; Detail="cert scan failed: $($_.Exception.Message)"; Value=$null; Items=@() }
    }
}

function Get-ScheduledTaskHealth {
    # Non-Microsoft scheduled tasks whose last run failed. Benign status codes
    # (ready/running/queued/disabled/not-yet-run) are excluded. Internally guarded.
    param([switch]$IncludeMicrosoft)
    try {
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            return [PSCustomObject]@{ Status='OK'; Detail='ScheduledTasks module not available'; Value=$null; Items=@() }
        }
        # Benign SCHED_S_* status codes (ready/running/has-not-run/no-more-runs/not-scheduled/queued).
        $benign = @(0, 0x41300, 0x41301, 0x41303, 0x41304, 0x41305, 0x41325)
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' })
        if (-not $IncludeMicrosoft) { $tasks = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }) }
        $failed = @()
        foreach ($t in $tasks) {
            $info = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            if ($info -and ($benign -notcontains $info.LastTaskResult)) {
                $failed += [PSCustomObject]@{ Task=$t.TaskName; Path=$t.TaskPath
                    LastRun=$info.LastRunTime; Result=('0x{0:X}' -f $info.LastTaskResult) }
            }
        }
        $st = if ($failed.Count -gt 0) { 'WARN' } else { 'OK' }
        $detail = if ($failed.Count -gt 0) {
            "$($failed.Count) task(s) failed last run: " + (($failed | Select-Object -First 5 -ExpandProperty Task) -join ', ')
        } else { 'no failed non-Microsoft tasks' }
        [PSCustomObject]@{ Status=$st; Detail=$detail; Value=$failed.Count; Items=$failed }
    } catch {
        [PSCustomObject]@{ Status='ERROR'; Detail="task scan failed: $($_.Exception.Message)"; Value=$null; Items=@() }
    }
}

function Get-SecurityPosture {
    # Read-only posture: Defender RTP/sig-age, firewall profiles, SMBv1, BitLocker
    # (physical), UAC. Each probe is guarded so a missing cmdlet never throws.
    $fails = @(); $warns = @()
    try { if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        # In passive/EDR mode a third-party AV owns real-time protection - don't fault Defender.
        if ($mp.AMRunningMode -and $mp.AMRunningMode -ne 'Normal') {
            # protected by another AV; no Defender RTP/sig-age finding
        } elseif (-not $mp.RealTimeProtectionEnabled) { $fails += 'Defender real-time protection OFF' }
        elseif ($mp.AntivirusSignatureAge -gt 3) { $warns += "AV signatures $($mp.AntivirusSignatureAge)d old" }
    } else { $warns += 'AV state unknown (Defender cmdlets absent)' } } catch {}
    try { if (Get-Command Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
        # Only flag when EVERY profile is off (a single intentionally-disabled profile is normal).
        $profs = @(Get-NetFirewallProfile -ErrorAction Stop)
        $off = @($profs | Where-Object { -not $_.Enabled })
        if ($profs.Count -gt 0 -and $off.Count -eq $profs.Count) { $fails += 'Windows Firewall OFF (all profiles)' }
    } } catch {}
    try { if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
        if ((Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol) { $fails += 'SMBv1 enabled' }
    } } catch {}
    try { if ((-not (Test-IsVirtual)) -and (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($bl -and $bl.ProtectionStatus -ne 'On') { $warns += "BitLocker off ($env:SystemDrive)" }
    } } catch {}
    try {
        $lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -ErrorAction Stop).EnableLUA
        if ($lua -ne 1) { $fails += 'UAC disabled' }
    } catch {}
    $st = if ($fails.Count -gt 0) { 'FAIL' } elseif ($warns.Count -gt 0) { 'WARN' } else { 'OK' }
    $detail = (@($fails) + @($warns)) -join '; '
    if (-not $detail) { $detail = 'Defender/firewall/SMBv1/UAC all OK' }
    [PSCustomObject]@{ Status=$st; Detail=$detail; Value=($fails.Count + $warns.Count); Items=(@($fails)+@($warns)) }
}

function Get-HealthSummary {
    # Returns an ordered list of health checks (Name/Status/Detail/Value). A
    # function-scope trap keeps one failing check from aborting the whole summary.
    # Shared by the on-screen check, the report, and the -RunCheck path.
    trap { continue }
    $checks = @()

    # --- Disk space (worst fixed drive) ---
    $worst = $null; $worstPct = 0
    foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        $tot = $d.Used + $d.Free
        if ($tot -le 0) { continue }
        $pct = [math]::Round($d.Used / $tot * 100, 0)
        if ($pct -gt $worstPct) { $worstPct = $pct; $worst = $d.Name }
    }
    $st = if ($worstPct -ge 90) { 'FAIL' } elseif ($worstPct -ge 80) { 'WARN' } else { 'OK' }
    $checks += [PSCustomObject]@{ Name = 'Disk space'; Status = $st; Detail = "highest used: ${worst}: ${worstPct}%"; Value = $worstPct }

    # --- Pending reboot ---
    $rb = Test-PendingReboot
    if ($rb.Count -gt 0) {
        $checks += [PSCustomObject]@{ Name = 'Pending reboot'; Status = 'WARN'; Detail = ($rb -join ', ') }
    } else {
        $checks += [PSCustomObject]@{ Name = 'Pending reboot'; Status = 'OK'; Detail = 'none' }
    }

    # --- Disk health (skip on VMs). On Dell hardware the PERC controller hides
    #     physical disks from Windows, so prefer racadm/iDRAC when available;
    #     otherwise fall back to Get-PhysicalDisk + SMART predicted-failure. ---
    if (-not (Test-IsVirtual)) {
        $dell = (Test-IsDell) -and (Get-RacadmPath)
        if ($dell) {
            $ds = Get-DellStorageHealth
            if ($ds) {
                $checks += [PSCustomObject]@{ Name = 'RAID/disk (iDRAC)'; Status = $ds.Status; Detail = $ds.Detail }
            }
        } else {
            $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue
            if ($pd) {
                $bad = @()
                foreach ($d in $pd) {
                    if ($d.HealthStatus -and $d.HealthStatus -ne 'Healthy') {
                        $bad += "$($d.FriendlyName): $($d.HealthStatus)"
                    }
                }
                $fp = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
                foreach ($f in $fp) { if ($f.PredictFailure) { $bad += 'SMART predicted failure' } }

                if ($bad.Count -gt 0) {
                    $checks += [PSCustomObject]@{ Name = 'Disk health'; Status = 'FAIL'; Detail = ($bad -join '; ') }
                } else {
                    $n = ($pd | Measure-Object).Count
                    $checks += [PSCustomObject]@{ Name = 'Disk health'; Status = 'OK'; Detail = "$n physical disk(s) healthy" }
                }
            }
        }
    }

    # --- Stopped automatic services ---
    $stopped = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
    $cnt = ($stopped | Measure-Object).Count
    if ($cnt -gt 0) {
        $names = ($stopped | Select-Object -First 4 -ExpandProperty Name) -join ', '
        $checks += [PSCustomObject]@{ Name = 'Auto services'; Status = 'WARN'; Detail = "$cnt stopped ($names)" }
    } else {
        $checks += [PSCustomObject]@{ Name = 'Auto services'; Status = 'OK'; Detail = 'all running' }
    }

    # --- Memory utilization ---
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os -and $os.TotalVisibleMemorySize -gt 0) {
        $memPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 0)
        $st = if ($memPct -ge 95) { 'FAIL' } elseif ($memPct -ge 85) { 'WARN' } else { 'OK' }
        $checks += [PSCustomObject]@{ Name = 'Memory'; Status = $st; Detail = "${memPct}% used"; Value = $memPct }
    }

    # --- Pagefile utilization ---
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pf -and $pf.AllocatedBaseSize -gt 0) {
        $pfPct = [math]::Round($pf.CurrentUsage / $pf.AllocatedBaseSize * 100, 0)
        $st = if ($pfPct -ge 95) { 'FAIL' } elseif ($pfPct -ge 80) { 'WARN' } else { 'OK' }
        $checks += [PSCustomObject]@{ Name = 'Pagefile'; Status = $st; Detail = "${pfPct}% used"; Value = $pfPct }
    }

    # --- Recent error events (System log, last 24h) ---
    $errCount = (Get-RecentSystemErrors -Hours 24 -Max 100 | Measure-Object).Count
    $detail = if ($errCount -ge 100) { '100+ error/critical event(s)' } else { "$errCount error/critical event(s)" }
    $st = if ($errCount -gt 0) { 'WARN' } else { 'OK' }
    $checks += [PSCustomObject]@{ Name = 'System errors (24h)'; Status = $st; Detail = $detail }

    # --- Network adapters (packet errors / discards, cumulative since boot) ---
    $nics = Get-NetworkAdapterHealth
    if ($nics) {
        $netErr  = ($nics | ForEach-Object { $_.RxErrors + $_.TxErrors }       | Measure-Object -Sum).Sum
        $netDisc = ($nics | ForEach-Object { $_.RxDiscarded + $_.TxDiscarded } | Measure-Object -Sum).Sum
        $st = if ($netErr -gt 0) { 'WARN' } else { 'OK' }
        $checks += [PSCustomObject]@{ Name = 'Network adapters'; Status = $st
            Detail = ("{0} up; errors: {1}, discards: {2} (since boot)" -f @($nics).Count, $netErr, $netDisc) }
    }

    # --- Default gateway reachability (ICMP ping) ---
    $gw = Get-GatewayHealth
    if ($gw) {
        $down = @($gw | Where-Object { -not $_.Reachable })
        $st = if ($down) { 'FAIL' } else { 'OK' }
        $detail = if ($down) { "unreachable: " + (($down | ForEach-Object { $_.Gateway }) -join ', ') }
                  else { "reachable: " + (($gw | ForEach-Object { $_.Gateway }) -join ', ') }
        $checks += [PSCustomObject]@{ Name = 'Default gateway'; Status = $st; Detail = $detail }
    }

    # --- NIC teaming (degraded = not Up or fewer active members than configured) ---
    $teams = Get-NicTeamingHealth
    if ($teams) {
        $deg = @($teams | Where-Object { $_.Status -ne 'Up' -or $_.Active -lt $_.Members -or $_.FailedMembers })
        $st = if ($deg) { 'WARN' } else { 'OK' }
        $detail = if ($deg) { (($deg | ForEach-Object { "$($_.Team) $($_.Active)/$($_.Members)" }) -join ', ') }
                  else { "$(@($teams).Count) team(s) healthy" }
        $checks += [PSCustomObject]@{ Name = 'NIC teaming'; Status = $st; Detail = $detail }
    }

    # --- DNS resolution (domain-joined only) ---
    $dns = Get-DnsHealth
    if ($null -ne $dns.Resolved) {
        $st = if ($dns.Resolved) { 'OK' } else { 'FAIL' }
        $detail = if ($dns.Resolved) { "resolved $($dns.Target)" } else { "cannot resolve $($dns.Target)" }
        $checks += [PSCustomObject]@{ Name = 'DNS resolution'; Status = $st; Detail = $detail }
    }

    # --- Network location (NLA) - wrong category blocks inbound ping ---
    $nloc = Get-NetworkLocationHealth
    $checks += [PSCustomObject]@{ Name = 'Network location'; Status = $nloc.Status; Detail = $nloc.Detail }

    # --- Hardware temperature / power (physical only) ---
    $hw = Get-HardwareHealth
    if ($hw -and $hw.Status -in @('OK','WARN','FAIL')) {
        $checks += [PSCustomObject]@{ Name = 'Hardware (temp/PSU)'; Status = $hw.Status; Detail = "$($hw.Detail) [$($hw.Source)]" }
    }

    # --- CPU / memory hardware faults (WHEA machine-check / ECC) ---
    $cmf = Get-CpuMemoryFaults
    $checks += [PSCustomObject]@{ Name = 'CPU/memory faults'; Status = $cmf.Status; Detail = $cmf.Detail }

    # --- Domain time drift ---
    $time = Get-TimeSyncHealth
    if ($time) {
        $checks += [PSCustomObject]@{ Name = 'Time sync'; Status = $time.Status; Detail = $time.Detail }
    }

    # --- Certificate expiry (server-auth certs in LocalMachine\My) ---
    $cert = Get-CertHealth
    $checks += [PSCustomObject]@{ Name = 'Certificate expiry'; Status = $cert.Status; Detail = $cert.Detail; Value = $cert.Value }

    # --- Failed scheduled tasks (non-Microsoft) ---
    $tasks = Get-ScheduledTaskHealth
    $checks += [PSCustomObject]@{ Name = 'Scheduled tasks'; Status = $tasks.Status; Detail = $tasks.Detail; Value = $tasks.Value }

    # --- Security posture (Defender/firewall/SMBv1/BitLocker/UAC) ---
    $sec = Get-SecurityPosture
    $checks += [PSCustomObject]@{ Name = 'Security posture'; Status = $sec.Status; Detail = $sec.Detail; Value = $sec.Value }

    # --- Listening ports / connections (informational) ---
    $lp = Get-ListeningPorts
    if ($null -ne $lp) {
        $tcpN = @($lp | Where-Object { $_.Proto -eq 'TCP' }).Count
        $udpN = @($lp | Where-Object { $_.Proto -eq 'UDP' }).Count
        $cs = Get-ConnectionSummary
        $est = if ($cs) { $cs.Established } else { 0 }
        $checks += [PSCustomObject]@{ Name = 'Listening ports'; Status = 'OK'
            Detail = "$tcpN TCP, $udpN UDP listening; $est established" }
    }

    # --- Uptime (informational) ---
    if ($os) {
        $uptime = (Get-Date) - $os.LastBootUpTime
        $checks += [PSCustomObject]@{ Name = 'Uptime'; Status = 'OK'
            Detail = ("{0}d {1}h since last boot" -f $uptime.Days, $uptime.Hours) }
    }

    return $checks
}

function Write-HealthSummary {
    param($Checks)
    Write-Header "Health Summary - $env:COMPUTERNAME"
    foreach ($c in $Checks) {
        $color = switch ($c.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
        Write-Host ("  [{0,-4}] {1,-20} {2}" -f $c.Status, $c.Name, $c.Detail) -ForegroundColor $color
    }
}

function Export-HealthReport {
    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outDir  = "$env:SystemDrive\AdminReports"
    $outFile = "$outDir\HealthReport_$env:COMPUTERNAME`_$stamp.txt"

    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir | Out-Null }

    $summary = @(Get-HealthSummary)
    $overall = if (@($summary).Count -eq 0) { 'UNKNOWN' }
               elseif ($summary.Status -contains 'FAIL') { 'FAIL' }
               elseif ($summary.Status -contains 'ERROR') { 'UNKNOWN' }
               elseif ($summary.Status -contains 'WARN') { 'WARN' }
               else { 'OK' }

    $report = & {
        "=" * 60
        "  SERVER HEALTH REPORT - $env:COMPUTERNAME"
        "  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "  Overall status: $overall"
        "=" * 60

        "`n[SUMMARY]"
        $summary | ForEach-Object { "  [{0,-4}] {1,-20} {2}" -f $_.Status, $_.Name, $_.Detail }

        "`n[DISK SPACE]"
        Get-PSDrive -PSProvider FileSystem |
            Select-Object Name,
                @{N='Used(GB)';  E={[math]::Round($_.Used/1GB,2)}},
                @{N='Free(GB)';  E={[math]::Round($_.Free/1GB,2)}},
                @{N='Total(GB)'; E={[math]::Round(($_.Used+$_.Free)/1GB,2)}},
                @{N='Used%';     E={ $t=$_.Used+$_.Free; if($t){[math]::Round($_.Used/$t*100,0)}else{0} }} |
            Format-Table -AutoSize | Out-String

        if (-not (Test-IsVirtual)) {
            if ((Test-IsDell) -and (Get-RacadmPath)) {
                "`n[STORAGE HEALTH - iDRAC / racadm]"
                $ds = Get-DellStorageHealth
                if ($ds) { "  Verdict: $($ds.Status) - $($ds.Detail)`n"; $ds.Raw } else { "  (racadm unavailable)`n" }
            } else {
                "`n[PHYSICAL DISK HEALTH]"
                $pd = Get-PhysicalDisk -ErrorAction SilentlyContinue |
                    Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus,
                        @{N='Size(GB)'; E={[math]::Round($_.Size/1GB,0)}}
                if ($pd) { $pd | Format-Table -AutoSize | Out-String } else { "  (no physical disk data)`n" }
            }
        }

        "`n[STOPPED AUTOMATIC SERVICES]"
        $svc = Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
            Select-Object DisplayName, Name, Status
        if ($svc) { $svc | Format-Table -AutoSize | Out-String } else { "  (none)`n" }

        "`n[NETWORK ADAPTERS - discards/errors cumulative since boot]"
        $nic = Get-NetworkAdapterHealth
        if ($nic) { $nic | Format-Table Name, LinkSpeed, RxDiscarded, RxErrors, TxDiscarded, TxErrors -AutoSize | Out-String }
        else { "  (Get-NetAdapter unavailable or no connected adapters)`n" }

        "`n[DEFAULT GATEWAY]"
        $gwr = Get-GatewayHealth
        if ($gwr) { $gwr | Format-Table Interface, Gateway, Reachable -AutoSize | Out-String }
        else { "  (no default gateway configured)`n" }

        "`n[NIC TEAMING]"
        $tm = Get-NicTeamingHealth
        if ($null -eq $tm) { "  (LBFO not available)`n" }
        elseif (-not $tm) { "  (no teams configured)`n" }
        else { $tm | Format-Table Team, Mode, LB, Status, Members, Active, FailedMembers -AutoSize | Out-String }

        "`n[DNS]"
        $dn = Get-DnsHealth
        "  Servers: $($dn.Servers)"
        if ($null -eq $dn.Resolved) { "  Resolution test: skipped (not domain-joined)" }
        elseif ($dn.Resolved) { "  Resolved $($dn.Target) -> $($dn.Addresses)" }
        else { "  FAILED to resolve $($dn.Target): $($dn.Error)" }

        "`n[NETWORK LOCATION - NLA / firewall profile]"
        $nlr = Get-NetworkLocationHealth
        "  [$($nlr.Status)] $($nlr.Detail)"

        "`n[LISTENING PORTS]"
        $lpr = Get-ListeningPorts
        if ($null -eq $lpr) { "  (Get-NetTCPConnection unavailable)`n" }
        elseif (-not $lpr) { "  (none)`n" }
        else { $lpr | Format-Table Proto, LocalAddress, Port, ProcessId, Process -AutoSize | Out-String }

        "`n[TCP CONNECTIONS BY STATE]"
        $csr = Get-ConnectionSummary
        if ($csr) { $csr.ByState | Format-Table State, Count -AutoSize | Out-String } else { "  (no data)`n" }

        "`n[HARDWARE - temperature / power]"
        $hwr = Get-HardwareHealth
        if ($null -eq $hwr) { "  (skipped - virtual machine)`n" }
        else { "  [$($hwr.Status)] $($hwr.Detail) (source: $($hwr.Source))"; if ($hwr.Raw) { $hwr.Raw } }

        "`n[CPU / MEMORY FAULTS - WHEA]"
        $cmr = Get-CpuMemoryFaults
        "  [$($cmr.Status)] $($cmr.Detail)"
        if ($cmr.Recent) { $cmr.Recent | ForEach-Object { "    $_" } }

        "`n[DOMAIN TIME SYNC]"
        $tsr = Get-TimeSyncHealth
        if ($null -eq $tsr) { "  (skipped - not domain-joined)`n" }
        else { "  [$($tsr.Status)] $($tsr.Detail)" }

        "`n[CERTIFICATE EXPIRY - server-auth, LocalMachine\My]"
        $cr = Get-CertHealth
        "  [$($cr.Status)] $($cr.Detail)"
        if ($cr.Items) {
            $cr.Items | Select-Object -First 10 Subject, Thumbprint,
                @{N='NotAfter';E={$_.NotAfter}}, DaysLeft | Format-Table -AutoSize | Out-String
        }

        "`n[FAILED SCHEDULED TASKS - non-Microsoft]"
        $sk = Get-ScheduledTaskHealth
        "  [$($sk.Status)] $($sk.Detail)"
        if ($sk.Items) { $sk.Items | Format-Table Task, Path, LastRun, Result -AutoSize | Out-String }

        "`n[SECURITY POSTURE]"
        $sp = Get-SecurityPosture
        "  [$($sp.Status)] $($sp.Detail)"

        "`n[RECENT SYSTEM ERRORS - last 24h]"
        $ev = Get-RecentSystemErrors -Hours 24 -Max 20 |
            Select-Object @{N='Time';E={$_.TimeCreated}}, @{N='Level';E={$_.LevelDisplayName}},
                @{N='Source';E={$_.ProviderName}}, @{N='ID';E={$_.Id}},
                @{N='Message';E={ ($_.Message -split "`r?`n")[0] }}
        if ($ev) { $ev | Format-Table -AutoSize -Wrap | Out-String } else { "  (none)`n" }

        "`n[TOP 10 PROCESSES - MEMORY]"
        Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10 Name, Id,
            @{N='Mem(MB)';       E={[math]::Round($_.WorkingSet/1MB,2)}},
            @{N='PrivateMem(MB)';E={[math]::Round($_.PrivateMemorySize64/1MB,2)}} |
            Format-Table -AutoSize | Out-String

        "`n[ACTIVE SESSIONS]"
        (query session 2>$null) -join "`n"

        "`n" + ("=" * 60)
        "  END OF REPORT"
        "=" * 60
    }

    $report | Out-File -FilePath $outFile -Encoding UTF8

    Write-HealthSummary $summary
    Write-Host ""
    Write-Host "  Overall: $overall" -ForegroundColor $(
        switch ($overall) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Magenta' } })
    Write-Host "  Report saved to: $outFile" -ForegroundColor Cyan
    Write-Host "  Size: $([math]::Round((Get-Item $outFile).Length / 1KB, 1)) KB" -ForegroundColor DarkCyan
}

function Invoke-SystemHealthCheck {
    Write-HealthSummary (Get-HealthSummary)
    Get-DiskSpace
    Get-TopResourceUsers -Seconds 3
    Show-NetworkStatus
    Show-HardwareHealth
    Show-CpuMemoryFaults
    Show-TimeSync
    Show-RecentSystemErrors
}

function Invoke-DiskCleanup {
    param([string]$Drive = 'C')

    $root = "${Drive}:\"
    if (-not (Test-Path $root)) {
        Write-Host "  Drive $Drive`: not found." -ForegroundColor Red
        return
    }

    Write-Header "Disk Cleanup - ${Drive}:"

    $targets = @(
        @{ Label = 'Windows Temp';               Path = "$env:SystemRoot\Temp" },
        @{ Label = 'User Temp';                  Path = "$env:TEMP" },
        @{ Label = 'Prefetch';                   Path = "$env:SystemRoot\Prefetch" },
        @{ Label = 'CBS Logs';                   Path = "$env:SystemRoot\Logs\CBS" },
        @{ Label = 'Memory Dump Files';          Path = "$env:SystemRoot\MEMORY.DMP"; IsFile = $true },
        @{ Label = 'Minidumps';                  Path = "$env:SystemRoot\Minidump" },
        @{ Label = 'IIS Logs';                   Path = "$env:SystemDrive\inetpub\logs\LogFiles" },
        @{ Label = 'SoftwareDistribution\Download'; Path = "$env:SystemRoot\SoftwareDistribution\Download" }
    )

    $preview = foreach ($t in $targets) {
        if (-not (Test-Path $t.Path)) { continue }
        if ($t.IsFile) {
            $f     = Get-Item $t.Path -ErrorAction SilentlyContinue
            $size  = if ($f) { $f.Length } else { 0 }
            $count = if ($f) { 1 } else { 0 }
        } else {
            $files = Get-ChildItem $t.Path -Recurse -Force -File -ErrorAction SilentlyContinue
            $size  = ($files | Measure-Object Length -Sum).Sum
            $count = $files.Count
        }
        [PSCustomObject]@{
            Location   = $t.Label
            Files      = $count
            'Size(MB)' = [math]::Round($size / 1MB, 2)
            Path       = $t.Path
        }
    }

    $totalMB = [math]::Round(($preview | Measure-Object 'Size(MB)' -Sum).Sum, 2)

    if (-not $preview -or $totalMB -eq 0) {
        Write-Host "  Nothing to clean on ${Drive}:." -ForegroundColor Green
        return
    }

    $preview | Select-Object Location, Files, 'Size(MB)' | Format-Table -AutoSize
    Write-Host "  Total recoverable: $totalMB MB" -ForegroundColor Yellow

    $confirm = Read-Host "`n  Proceed with cleanup? [Y/N]"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "  Cleanup cancelled." -ForegroundColor Yellow
        return
    }

    $wuWasRunning = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running'
    if ($wuWasRunning) { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue }

    $freed = 0
    foreach ($t in $targets) {
        if (-not (Test-Path $t.Path)) { continue }
        try {
            if ($t.IsFile) {
                $f = Get-Item $t.Path -ErrorAction SilentlyContinue
                if ($f) { $freed += $f.Length; Remove-Item $t.Path -Force -ErrorAction SilentlyContinue }
            } else {
                $files  = Get-ChildItem $t.Path -Recurse -Force -File -ErrorAction SilentlyContinue
                $freed += ($files | Measure-Object Length -Sum).Sum
                Remove-Item "$($t.Path)\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Host "  Cleaned: $($t.Label)" -ForegroundColor Green
        } catch {
            Write-Host "  Skipped: $($t.Label) - $_" -ForegroundColor DarkYellow
        }
    }

    if ($wuWasRunning) { Start-Service wuauserv -ErrorAction SilentlyContinue }

    $freedMB = [math]::Round($freed / 1MB, 2)
    Write-Host "`n  Done. Freed approximately $freedMB MB on ${Drive}:." -ForegroundColor Cyan

    $drv = Get-PSDrive -Name $Drive -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($drv) {
        $usedGB  = [math]::Round($drv.Used / 1GB, 2)
        $freeGB  = [math]::Round($drv.Free / 1GB, 2)
        $totalGB = [math]::Round(($drv.Used + $drv.Free) / 1GB, 2)
        Write-Host "  ${Drive}: - Used: ${usedGB} GB  Free: ${freeGB} GB  Total: ${totalGB} GB" -ForegroundColor White
    }
}

function Show-AdminMenu {
    Show-Banner
    $admin = Test-IsAdmin
    while ($true) {
        Write-Host "`n" -NoNewline
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "  SERVER ADMIN MENU  -  $env:COMPUTERNAME  " -ForegroundColor White -NoNewline
        if ($admin) {
            Write-Host "[Administrator]" -ForegroundColor Green
        } else {
            Write-Host "[Standard user]" -ForegroundColor Yellow
        }
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "  System & Diagnostics" -ForegroundColor DarkCyan
        Write-Host "  [1]  Disk Space"              -ForegroundColor Green
        Write-Host "  [2]  Top Resource Users (live)"-ForegroundColor Green
        Write-Host "  [3]  Restart / Kill a Service"-ForegroundColor Yellow
        Write-Host "  [4]  Pending Windows Updates" -ForegroundColor Yellow
        Write-Host "  [5]  Full System Health Check"-ForegroundColor Cyan
        Write-Host "  [M]  Top 10 Memory Usage"     -ForegroundColor Green
        Write-Host "  [S]  Top 10 Swap/Page File"   -ForegroundColor Green
        Write-Host "  [A]  Active User Sessions"    -ForegroundColor Green
        Write-Host "  [L]  Tail a Log File"         -ForegroundColor Green
        Write-Host ""
        Write-Host "  Networking" -ForegroundColor DarkCyan
        Write-Host "  [N]  Adapters, teaming, DNS, gateway" -ForegroundColor Green
        Write-Host "  [P]  Listening Ports / Connections"   -ForegroundColor Green
        Write-Host ""
        Write-Host "  Maintenance" -ForegroundColor DarkCyan
        Write-Host "  [C]  Disk Cleanup (C: drive)" -ForegroundColor Magenta
        Write-Host "  [E]  Export Health Report"    -ForegroundColor DarkCyan
        Write-Host ""
        if (-not $admin) {
            Write-Host "  [R]  Relaunch as Administrator" -ForegroundColor Red
        }
        Write-Host "  [0]  Exit to Shell"           -ForegroundColor Red
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        if (-not $admin) {
            Write-Host "  Note: tasks like " -ForegroundColor DarkGray -NoNewline
            Write-Host "[3]" -ForegroundColor Yellow -NoNewline
            Write-Host " and " -ForegroundColor DarkGray -NoNewline
            Write-Host "[C]" -ForegroundColor Magenta -NoNewline
            Write-Host " need admin - press " -ForegroundColor DarkGray -NoNewline
            Write-Host "[R]" -ForegroundColor Red -NoNewline
            Write-Host " to elevate." -ForegroundColor DarkGray
        }
        Write-Host "  Tip: after a task, press " -ForegroundColor DarkGray -NoNewline
        Write-Host "[X]" -ForegroundColor Red -NoNewline
        Write-Host " then Enter to exit  -  type " -ForegroundColor DarkGray -NoNewline
        Write-Host "Show-AdminMenu" -ForegroundColor Cyan -NoNewline
        Write-Host " to reopen." -ForegroundColor DarkGray

        $choice = Read-Host "`n  Select an option"
        if ($null -eq $choice) { return }   # input stream closed / non-interactive - bail, don't loop

        $ranTask = $true
        switch (([string]$choice).ToUpper()) {
            '1' { Get-DiskSpace -IncludeTopFiles }
            '2' { Get-TopResourceUsers }
            '3' { Restart-ServiceByName }
            '4' { Get-PendingUpdates }
            '5' { Invoke-SystemHealthCheck }
            'M' { Get-TopMemory }
            'S' { Get-SwapUsage }
            'A' { Get-ActiveSessions }
            'L' { Show-LogTail }
            'N' { Show-NetworkStatus }
            'P' { Show-PortsConnections }
            'C' { Invoke-DiskCleanup -Drive 'C' }
            'E' { Export-HealthReport }
            'R' { Invoke-RelaunchAsAdmin }
            '0' {
                Write-Host "`n  Exiting menu. Type 'Show-AdminMenu' to return.`n" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "  Invalid option. Please choose 0-5, A, C, E, L, M, N, P, R, or S." -ForegroundColor Red
                $ranTask = $false
            }
        }

        if ($ranTask) {
            Write-Host "`n  [Enter] Return to menu    [X] Exit to shell" -ForegroundColor DarkGray
            $after = Read-Host "  Choose"
            if ($after -match '^[Xx]') {
                Write-Host "`n  Exiting menu. Type 'Show-AdminMenu' to return.`n" -ForegroundColor Cyan
                return
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  Entry point. Dot-sourced as a profile (no params) -> interactive menu.
#  Run as a script with -RunCheck -> non-interactive health check + exit code.
# ---------------------------------------------------------------------------
if ($RunCheck) {
    # 6>$null guards JSON/stdout against any stray Write-Host from a future probe.
    $summary = @(Get-HealthSummary 6>$null)
    $overall = if (@($summary).Count -eq 0)               { 'UNKNOWN' }   # check engine produced nothing
               elseif ($summary.Status -contains 'FAIL')  { 'FAIL' }
               elseif ($summary.Status -contains 'ERROR') { 'UNKNOWN' }
               elseif ($summary.Status -contains 'WARN')  { 'WARN' }
               else                                       { 'OK' }

    if ($AsJson) {
        [PSCustomObject]@{
            host      = $env:COMPUTERNAME
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
            overall   = $overall
            checks    = @($summary | Select-Object Name, Status, Detail, Value)
        } | ConvertTo-Json -Depth 5 -Compress
    } elseif (-not $Quiet) {
        Write-HealthSummary $summary
        Write-Host "`n  Overall: $overall" -ForegroundColor $(
            switch ($overall) { 'OK' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} default {'Magenta'} })
    }

    $code = switch ($overall) { 'OK' {0} 'WARN' {1} 'FAIL' {2} default {3} }
    # Only 'exit' when actually run as a script; never kill a shell that dot-sourced us.
    if ($MyInvocation.InvocationName -ne '.') { exit $code }
}
elseif ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and
        -not [Console]::IsInputRedirected -and
        ([Environment]::GetCommandLineArgs() -notcontains '-NonInteractive')) {
    # Launch the menu ONLY in a real interactive console. Skipping it in remoting /
    # Invoke-Command / -NonInteractive / piped-stdin / scheduled-task sessions keeps the
    # menu's Read-Host from hanging or spinning when this loads as the AllUsers profile.
    Show-AdminMenu
}
