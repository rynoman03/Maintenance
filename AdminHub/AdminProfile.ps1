#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Administrative PowerShell profile applied to all users on Windows Servers.
    Presents an interactive menu of common administrative tasks on shell startup.
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
#>

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

function prompt {
    $user   = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $host_  = $env:COMPUTERNAME
    $path   = (Get-Location).Path
    Write-Host "[ADMIN] " -ForegroundColor Red -NoNewline
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

function Get-DiskSpace {
    Write-Header "Disk Space"
    Get-PSDrive -PSProvider FileSystem |
        Select-Object Name,
            @{N='Used(GB)';  E={[math]::Round($_.Used/1GB,2)}},
            @{N='Free(GB)';  E={[math]::Round($_.Free/1GB,2)}},
            @{N='Total(GB)'; E={[math]::Round(($_.Used+$_.Free)/1GB,2)}} |
        Format-Table -AutoSize
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
        Write-Host "`n  Top $Top by CPU (% of total CPU):" -ForegroundColor Cyan
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
    Write-Host "  Top $Top by Memory (working set):" -ForegroundColor Cyan
    Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First $Top Name, Id,
        @{N='Mem(MB)';       E={[math]::Round($_.WorkingSet / 1MB, 2)}},
        @{N='PrivateMem(MB)';E={[math]::Round($_.PrivateMemorySize64 / 1MB, 2)}} |
        Format-Table -AutoSize
}

function Restart-ServiceByName {
    $name = Read-Host "  Enter service name to restart"
    if ([string]::IsNullOrWhiteSpace($name)) { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    try {
        Restart-Service -Name $name -Force -ErrorAction Stop
        Write-Host "  '$name' restarted successfully." -ForegroundColor Green
    } catch {
        Write-Host "  Error: $_" -ForegroundColor Red
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

function Get-HealthSummary {
    # Returns an ordered list of health checks, each with Status (OK/WARN/FAIL)
    # and a short Detail string. Shared by the on-screen check and the report.
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
    $checks += [PSCustomObject]@{ Name = 'Disk space'; Status = $st; Detail = "highest used: ${worst}: ${worstPct}%" }

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
        $checks += [PSCustomObject]@{ Name = 'Memory'; Status = $st; Detail = "${memPct}% used" }
    }

    # --- Pagefile utilization ---
    $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pf -and $pf.AllocatedBaseSize -gt 0) {
        $pfPct = [math]::Round($pf.CurrentUsage / $pf.AllocatedBaseSize * 100, 0)
        $st = if ($pfPct -ge 95) { 'FAIL' } elseif ($pfPct -ge 80) { 'WARN' } else { 'OK' }
        $checks += [PSCustomObject]@{ Name = 'Pagefile'; Status = $st; Detail = "${pfPct}% used" }
    }

    # --- Recent error events (System log, last 24h) ---
    $since = (Get-Date).AddHours(-24)
    $errCount = (Get-EventLog -LogName System -EntryType Error -After $since -ErrorAction SilentlyContinue |
        Measure-Object).Count
    $st = if ($errCount -gt 0) { 'WARN' } else { 'OK' }
    $checks += [PSCustomObject]@{ Name = 'System errors (24h)'; Status = $st; Detail = "$errCount error event(s)" }

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

    $summary = Get-HealthSummary
    $overall = if ($summary.Status -contains 'FAIL') { 'FAIL' }
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

        "`n[RECENT SYSTEM ERRORS - last 24h]"
        $ev = Get-EventLog -LogName System -EntryType Error -After ((Get-Date).AddHours(-24)) -Newest 20 -ErrorAction SilentlyContinue |
            Select-Object TimeGenerated, Source, EventID, Message
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
        switch ($overall) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } })
    Write-Host "  Report saved to: $outFile" -ForegroundColor Cyan
    Write-Host "  Size: $([math]::Round((Get-Item $outFile).Length / 1KB, 1)) KB" -ForegroundColor DarkCyan
}

function Invoke-SystemHealthCheck {
    Write-HealthSummary (Get-HealthSummary)
    Get-DiskSpace
    Get-TopResourceUsers -Seconds 3
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
    while ($true) {
        Write-Host "`n" -NoNewline
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "  SERVER ADMIN MENU  -  $env:COMPUTERNAME" -ForegroundColor White
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "  [1]  Disk Space"              -ForegroundColor Green
        Write-Host "  [2]  Top Resource Users (live)"-ForegroundColor Green
        Write-Host "  [3]  Restart a Service"       -ForegroundColor Yellow
        Write-Host "  [4]  Pending Windows Updates" -ForegroundColor Yellow
        Write-Host "  [5]  Full System Health Check"-ForegroundColor Cyan
        Write-Host "  [M]  Top 10 Memory Usage"     -ForegroundColor Green
        Write-Host "  [S]  Top 10 Swap/Page File"   -ForegroundColor Green
        Write-Host "  [A]  Active User Sessions"    -ForegroundColor Green
        Write-Host "  [C]  Disk Cleanup (C: drive)" -ForegroundColor Magenta
        Write-Host "  [E]  Export Health Report"    -ForegroundColor DarkCyan
        Write-Host "  [0]  Exit to Shell"           -ForegroundColor Red
        Write-Host ("=" * 60) -ForegroundColor DarkGray
        Write-Host "  Tip: after a task, press " -ForegroundColor DarkGray -NoNewline
        Write-Host "[X]" -ForegroundColor Red -NoNewline
        Write-Host " then Enter to exit  -  type " -ForegroundColor DarkGray -NoNewline
        Write-Host "Show-AdminMenu" -ForegroundColor Cyan -NoNewline
        Write-Host " to reopen." -ForegroundColor DarkGray

        $choice = Read-Host "`n  Select an option"

        $ranTask = $true
        switch ($choice.ToUpper()) {
            '1' { Get-DiskSpace }
            '2' { Get-TopResourceUsers }
            '3' { Restart-ServiceByName }
            '4' { Get-PendingUpdates }
            '5' { Invoke-SystemHealthCheck }
            'M' { Get-TopMemory }
            'S' { Get-SwapUsage }
            'A' { Get-ActiveSessions }
            'C' { Invoke-DiskCleanup -Drive 'C' }
            'E' { Export-HealthReport }
            '0' {
                Write-Host "`n  Exiting menu. Type 'Show-AdminMenu' to return.`n" -ForegroundColor Cyan
                return
            }
            default {
                Write-Host "  Invalid option. Please choose 0-5, A, C, E, M, or S." -ForegroundColor Red
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

Show-AdminMenu
