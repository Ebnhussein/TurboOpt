<#
  Windows Turbo Optimizer Pro v11.0
  Run through TurboOptimizer.bat, or:  powershell -ExecutionPolicy Bypass -File TurboOptimizer.ps1 [-DryRun] [-SelfTest]
  -DryRun   : show what would happen, change nothing
  -SelfTest : run every task in dry-run, non-interactive, no admin needed
  Settings live in config.ini next to this script. Every change is recorded in turbo_undo.json (menu option 20 reverts).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$DryRun, [switch]$Doctor, [switch]$ScanOnly, [switch]$Maintain, [switch]$AsLibrary, [switch]$Console, [switch]$Browser, [switch]$Monitor)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # hides the blue PowerShell progress banner; we draw our own
$script:Version    = '12.3'
$script:Dir        = $PSScriptRoot
$script:LogFile    = Join-Path $script:Dir 'turbo_log.txt'
$script:Journal    = Join-Path $script:Dir 'turbo_undo.json'
$script:ConfigFile = Join-Path $script:Dir 'config.ini'
$script:BackupDir  = Join-Path $script:Dir 'turbo_backups'
$script:DryRun     = [bool]$DryRun
$script:AutoYes    = $false
$script:GuidRx     = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'

# Last-resort guard: keep the window open so a startup crash can be read.
trap {
    # -AsLibrary = loaded by the graphical version: log the error and carry on, never block on a prompt.
    if ($AsLibrary) { try { Add-ErrorRecord 'Unexpected error' $_ } catch {}; continue }
    Write-Host ''
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    try { Add-ErrorRecord 'Fatal error' $_ } catch {}
    if (-not $SelfTest) { Read-Host 'Press Enter to close' | Out-Null }
    break
}

# ---------------------------------------------------------------- admin
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $SelfTest -and -not $AsLibrary -and -not (Test-Admin)) {
    Write-Host 'Requesting administrator rights...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($DryRun) { $argList += '-DryRun' }
    if ($Browser) { $argList += '-Browser' }
    if ($Console) { $argList += '-Console' }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------- config
$DefaultConfig = @'
; Turbo Optimizer settings. Lists are comma separated. 1 = on, 0 = off.

[Clean]
UserTemp=1
WindowsTemp=1
WindowsUpdateCache=1
BrowserCaches=1
; Windows component cleanup (DISM) is thorough but takes several minutes.
ComponentCleanup=0
; Prefetch is rebuilt by Windows; cleaning it rarely helps.
Prefetch=0
; Permanently empties the Recycle Bin (always asks first).
RecycleBin=0

[Debloat]
Apps=Microsoft.3DBuilder,Microsoft.SkypeApp,Microsoft.MicrosoftOfficeHub,Microsoft.BingWeather,Microsoft.BingNews,Microsoft.549981C3F5F10
; Asked about one by one, never removed in All-in-one.
Optional=microsoft.windowscommunicationsapps

[Services]
; Each one is asked about individually. SysMain: keep it on a hard drive.
Candidates=DiagTrack,dmwappushservice,MapsBroker,Fax,RetailDemo,WMPNetworkSvc,SysMain

[Startup]
; Items whose name contains one of these cannot be disabled from the manager.
Protected=SecurityHealth,Defender,Antivirus,Security

[Turbo]
DefenderCpuCap=25

[Update]
; winget ids that update themselves when you open them; skipped here (Spotify refuses admin installers).
SelfUpdating=Spotify.Spotify

[UpdateProcesses]
; Optional: <winget id>=<process names that must be closed before updating>, comma separated.
; Common ones are built in (VS Code, Windows Terminal, Chrome, Firefox, Edge...).
; Example: Some.App=someapp,someapphelper
'@

function Read-Config {
    if (-not (Test-Path $script:ConfigFile)) { Set-Content -Path $script:ConfigFile -Value $DefaultConfig -Encoding ASCII }
    $cfg = @{}
    $sec = ''
    foreach ($line in Get-Content $script:ConfigFile) {
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith(';') -or $l.StartsWith('#')) { continue }
        if ($l -match '^\[(.+)\]$') {
            $sec = $Matches[1]
            if (-not $cfg.ContainsKey($sec)) { $cfg[$sec] = @{} }
            continue
        }
        $i = $l.IndexOf('=')
        if ($i -gt 0 -and $sec) { $cfg[$sec][$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim() }
    }
    $cfg
}
function Get-Cfg([string]$Section, [string]$Key, [string]$Default = '') {
    if ($script:Cfg.ContainsKey($Section) -and $script:Cfg[$Section].ContainsKey($Key)) { $script:Cfg[$Section][$Key] } else { $Default }
}
function Get-CfgList([string]$Section, [string]$Key) {
    @((Get-Cfg $Section $Key '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$script:Cfg = Read-Config

# ---------------------------------------------------------------- ui / log
function Write-Log([string]$Message) {
    try { Add-Content -Path $script:LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) } catch {}
}
function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

# ---- progress helpers ----
$script:OkCount = 0
$script:WorkLen = 0
function Format-Bar([int]$Done, [int]$Total, [int]$Width = 20) {
    if ($Total -lt 1) { $Total = 1 }
    $fill = [int][math]::Floor($Width * [math]::Min($Done, $Total) / $Total)
    return (([string][char]0x2588) * $fill) + (([string][char]0x2591) * ($Width - $fill))
}
function Format-Duration([TimeSpan]$T) {
    if ($T.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int][math]::Floor($T.TotalMinutes), $T.Seconds) }
    return ('{0}s' -f [int][math]::Round($T.TotalSeconds))
}
function Show-Step([int]$Index, [int]$Total, [string]$Title) {
    $pct = [int](100 * ($Index - 1) / $Total)
    Write-Host ''
    Write-Host ('  STEP {0}/{1}  ' -f $Index, $Total) -NoNewline -ForegroundColor White
    Write-Host (Format-Bar ($Index - 1) $Total 24) -NoNewline -ForegroundColor Cyan
    Write-Host ('  {0,3}%   {1}' -f $pct, $Title) -ForegroundColor White
}
# A temporary "working" line that the final result line replaces.
function Working-Begin([string]$Text) {
    if ($Text.Length -gt 68) { $Text = $Text.Substring(0, 65) + '...' }
    $line = "  [..]  $Text"
    $script:WorkLen = $line.Length
    Write-Host $line -NoNewline -ForegroundColor DarkYellow
}
function Working-End {
    if ($script:WorkLen -gt 0) { Write-Host ("`r" + (' ' * $script:WorkLen) + "`r") -NoNewline }
    $script:WorkLen = 0
}
$script:Unattended = $false   # scheduled maintenance: never asks, so every question counts as "no"
function Ask([string]$Question) {
    if ($script:Unattended) { return $false }
    if ($script:AutoYes) { return $true }
    $r = Read-Host "$Question [Y/N]"
    return ($r -match '^(y|yes)$')
}

# ---- problem collector: every failure/skip is shown after the action and saved with full detail ----
$script:ErrFile = Join-Path $script:Dir 'turbo_errors.log'
$script:Problems = New-Object System.Collections.ArrayList
$script:ProblemCursor = 0
function Add-Problem([string]$Where, [string]$What, [string]$Detail = '', [string]$Level = 'ERROR') {
    $p = [pscustomobject]@{ Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Level = $Level; Where = $Where; What = $What; Detail = $Detail }
    [void]$script:Problems.Add($p)
    try {
        Add-Content -Path $script:ErrFile -Value ("[{0}] {1} | {2}`r`n    {3}`r`n    {4}`r`n" -f $p.Time, $Level, $Where, $What, $Detail)
    } catch {}
    Write-Log "PROBLEM [$Level] $Where : $What"
}
function Add-ErrorRecord([string]$Where, $Rec) {
    $d = '{0} | id={1} | line {2}: {3}' -f $Rec.Exception.GetType().Name, $Rec.FullyQualifiedErrorId, $Rec.InvocationInfo.ScriptLineNumber, "$($Rec.InvocationInfo.Line)".Trim()
    if ($Rec.ScriptStackTrace) { $d += "`r`n    stack: " + ($Rec.ScriptStackTrace -replace "`r?`n", ' <- ') }
    Add-Problem $Where $Rec.Exception.Message $d
}
function Show-Problems {
    $new = @($script:Problems | Select-Object -Skip $script:ProblemCursor)
    $script:ProblemCursor = $script:Problems.Count
    Write-Host ''
    if ($new.Count -eq 0) { Say '  No problems detected in this action.' Green; return }
    Say ('  PROBLEMS ({0}) - full detail saved in {1}' -f $new.Count, $script:ErrFile) Yellow
    $i = 0
    foreach ($p in $new) {
        $i++
        $c = 'Red'
        if ($p.Level -eq 'WARN') { $c = 'Yellow' }
        Say ('  {0}. [{1}] {2}' -f $i, $p.Level, $p.Where) $c
        Say ('       {0}' -f $p.What) $c
        if ($p.Detail) { Say ('       {0}' -f ($p.Detail -replace "`r`n\s*", ' / ')) DarkGray }
    }
}
function Write-ErrHeader {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $hdr = "==== Session {0} | TurboOptimizer v{1} | PowerShell {2} | {3} build {4} | admin={5} | dryrun={6}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:Version, $PSVersionTable.PSVersion, $os.Caption, $os.BuildNumber, (Test-Admin), $script:DryRun
        Add-Content -Path $script:ErrFile -Value $hdr
    } catch {}
}
function Pause-Menu {
    Show-Problems
    if (-not $script:AutoYes) { Read-Host 'Press Enter to return to the menu' | Out-Null }
}
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# Runs an action; in dry-run only describes it. Never writes to the pipeline.
function Invoke-Act([string]$Desc, [scriptblock]$Action) {
    if ($script:DryRun) {
        Say "  [DRY] $Desc" DarkYellow
        Write-Log "[DRY] $Desc"
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Working-Begin $Desc
    try {
        & $Action | Out-Null
        Working-End
        $t = ''
        if ($sw.Elapsed.TotalSeconds -ge 2) { $t = '  (' + (Format-Duration $sw.Elapsed) + ')' }
        Say "  [OK]  $Desc$t" Green
        Write-Log "OK   $Desc$t"
        $script:OkCount++
    } catch {
        Working-End
        Say "  [x]   $Desc : $($_.Exception.Message)" Red
        Write-Log "FAIL $Desc : $($_.Exception.Message)"
        Add-ErrorRecord $Desc $_
    }
}

# ---- closing apps (ask first) and running as a normal user ----
function Get-AncestorPids {
    $ids = @()
    $cur = $PID
    for ($i = 0; $i -lt 12 -and $cur; $i++) {
        $ids += $cur
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        $cur = $p.ParentProcessId
        if ($ids -contains $cur) { break }
    }
    # the browser version runs in its own app window (separate profile folder): never treat it as a program to close
    try { $ids += @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*turbo_optimizer_browser*' } | ForEach-Object { [int]$_.ProcessId }) } catch {}
    return $ids
}
# Returns $true when nothing is blocking (not running, or the user let us close it).
# Returns $false when the user chose to keep it open (the caller should skip that step).
function Confirm-CloseApps([string[]]$ProcNames, [string]$Reason) {
    $procs = @()
    foreach ($n in $ProcNames) { $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue) }
    if ($procs.Count -eq 0) { return $true }
    if ($script:Unattended) { return $false }
    $own = Get-AncestorPids
    $blocking = @($procs | Where-Object { $own -notcontains $_.Id })
    $names = (($procs | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', ')
    if ($blocking.Count -eq 0) {
        Say "  $names hosts this window, so it cannot be closed from here. Close it yourself to include it." Yellow
        return $false
    }
    Say "  $names is running. $Reason" Yellow
    if ($script:DryRun) { Say "  [DRY] would ask to close $names" DarkYellow; return $true }
    if (-not (Ask "  Close $names now? Unsaved work in it will be lost")) { return $false }
    foreach ($p in $blocking) { try { [void]$p.CloseMainWindow() } catch {} }
    Start-Sleep -Seconds 4
    foreach ($p in $blocking) {
        $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        if ($alive) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 1
    $left = @($ProcNames | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue } | Where-Object { $own -notcontains $_.Id })
    if ($left.Count -gt 0) { Say "  Could not close $names." Yellow; return $false }
    Say "  Closed $names." DarkGray
    Write-Log "Closed $names on request"
    return $true
}
# Runs a command line as the SAME user but without administrator rights, through a one-shot
# scheduled task with a limited token. Needed for installers that refuse to run elevated (Spotify).
function Invoke-Unelevated([string]$CommandLine, [int]$TimeoutSec = 900) {
    $id = 'TurboOpt_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path $env:TEMP "$id.out"
    $user = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ({0}) > "{1}" 2>&1' -f $CommandLine, $outFile)
        $prin = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSec)
        Register-ScheduledTask -TaskName $id -Action $act -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $id -ErrorAction Stop
        Start-Sleep -Milliseconds 1200
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-ScheduledTask -TaskName $id -ErrorAction SilentlyContinue).State -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Seconds 1 }
        $raw = [uint32](Get-ScheduledTaskInfo -TaskName $id -ErrorAction Stop).LastTaskResult
        $code = [BitConverter]::ToInt32([BitConverter]::GetBytes($raw), 0)
        $out = ''
        if (Test-Path $outFile) { $out = Get-Content $outFile -Raw }
        return [pscustomobject]@{ ExitCode = $code; Output = $out }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "could not start a normal-user task: $($_.Exception.Message)" }
    } finally {
        Unregister-ScheduledTask -TaskName $id -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- undo journal
function Get-Journal {
    if (-not (Test-Path $script:Journal)) { return @() }
    $raw = Get-Content $script:Journal -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    # Windows PowerShell 5.1 wraps arrays oddly ({value, Count}); flatten them, including files written by older versions.
    $parsed = ConvertFrom-Json -InputObject $raw
    $out = @()
    foreach ($x in $parsed) {
        $names = @($x.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names -contains 'value' -and $names -contains 'Count') { foreach ($y in $x.value) { $out += $y } }
        else { $out += $x }
    }
    return $out
}
function Save-Journal($Entries) {
    ConvertTo-Json -InputObject @($Entries) -Depth 6 | Set-Content -Path $script:Journal -Encoding UTF8
}
function Add-Journal([hashtable]$Entry) {
    if ($script:DryRun) { return }
    $Entry['Time'] = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $j = @(Get-Journal)
    $j += [pscustomobject]$Entry
    Save-Journal $j
}

# ---------------------------------------------------------------- system info / metrics
function Get-SysInfo {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
    $disks = @()
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { '{0} ({1} GB, {2})' -f $_.FriendlyName, [math]::Round($_.Size / 1GB), $_.MediaType })
    } catch {
        $disks = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { $_.Model })
    }
    [pscustomobject]@{ CPU = $cpu; RAM = $ram; GPU = $gpu; Disks = $disks }
}

function Get-Metrics {
    $os = Get-CimInstance Win32_OperatingSystem
    $c = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $boot = $null
    try {
        $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
        $x = [xml]$e.ToXml()
        $n = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
        if ($n) { $boot = [math]::Round([double]$n / 1000, 1) }
    } catch {}
    [pscustomobject]@{
        FreeGB       = [math]::Round($c.Free / 1GB, 2)
        RamUsedPct   = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
        Processes    = @(Get-Process).Count
        StartupItems = @(Get-StartupItems).Count
        LastBootSec  = $boot
    }
}
function Show-Compare($Before, $After) {
    Say ('  {0,-16}{1,10}{2,10}{3,10}' -f 'Metric', 'Before', 'After', 'Change') White
    $rows = @(
        @{ K = 'FreeGB';       L = 'Free disk (GB)'; Up = $true },
        @{ K = 'RamUsedPct';   L = 'RAM used (%)';   Up = $false },
        @{ K = 'Processes';    L = 'Processes';      Up = $false },
        @{ K = 'StartupItems'; L = 'Startup items';  Up = $false },
        @{ K = 'LastBootSec';  L = 'Last boot (s)';  Up = $false }
    )
    foreach ($r in $rows) {
        $b = $Before.($r.K); $a = $After.($r.K)
        $ch = ''
        $c = 'Gray'
        if ($null -ne $b -and $null -ne $a) {
            $d = [math]::Round([double]$a - [double]$b, 2)
            $ch = ('{0:+0.##;-0.##;0}' -f $d)
            if ($d -ne 0) { if (($d -gt 0) -eq $r.Up) { $c = 'Green' } else { $c = 'Red' } }
        }
        Say ('  {0,-16}{1,10}{2,10}{3,10}' -f $r.L, $b, $a, $ch) $c
        Write-Log ('METRIC {0}: {1} -> {2}' -f $r.K, $b, $a)
    }
    Say '  Free space can drop after updates install and the restore point is stored.' DarkGray
}

# ---------------------------------------------------------------- restore point
function Invoke-RestorePoint {
    Say '[+] Restore point' Cyan
    if ($script:DryRun) { Say '  [DRY] Create system restore point' DarkYellow; Write-Log '[DRY] Restore point'; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Working-Begin 'Creating restore point (can take up to a minute)'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        $b = (Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber | Select-Object -Last 1).SequenceNumber
        Checkpoint-Computer -Description 'TurboOptimizer_v11' -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue -ErrorAction Stop
        $a = (Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object SequenceNumber | Select-Object -Last 1).SequenceNumber
        Working-End
        if ($a -ne $b) { Say ('  [OK]  Restore point created  ({0})' -f (Format-Duration $sw.Elapsed)) Green; Write-Log 'Restore point created'; $script:OkCount++ }
        else { Say '  [--]  Skipped: Windows allows one restore point per 24 hours by default' Yellow; Write-Log 'Restore point skipped (24h limit)' }
    } catch {
        Working-End
        Say "  [x]   Restore point failed: $($_.Exception.Message)" Red
        Write-Log "Restore point FAILED: $($_.Exception.Message)"
        Add-ErrorRecord 'Create restore point' $_
    }
}

# ---------------------------------------------------------------- clean
function Resolve-Dirs([string[]]$Paths) {
    foreach ($p in $Paths) { Resolve-Path -Path $p -ErrorAction SilentlyContinue | ForEach-Object { $_.ProviderPath } }
}
function Get-DirSize([string[]]$Paths) {
    $sum = [int64]0
    foreach ($d in (Resolve-Dirs $Paths)) {
        $s = (Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($s) { $sum += [int64]$s }
    }
    $sum
}
function Get-RecycleSize {
    try {
        $bin = (New-Object -ComObject Shell.Application).Namespace(0xA)
        $s = [int64]0
        foreach ($i in $bin.Items()) { $s += [int64]$i.Size }
        $s
    } catch { [int64]0 }
}
function New-Target($Name, $Paths, $Procs = @(), $Svcs = @(), $Special = '') {
    [pscustomobject]@{ Name = $Name; Paths = @($Paths); Procs = @($Procs); Svcs = @($Svcs); Special = $Special; Size = [int64]0 }
}
function Get-CleanTargets {
    $lad = $env:LOCALAPPDATA
    $win = $env:SystemRoot
    $t = @()
    if ((Get-Cfg 'Clean' 'UserTemp' '1') -eq '1')   { $t += New-Target 'User temp files' @($env:TEMP) }
    if ((Get-Cfg 'Clean' 'WindowsTemp' '1') -eq '1') { $t += New-Target 'Windows temp files' @("$win\Temp") }
    if ((Get-Cfg 'Clean' 'WindowsUpdateCache' '1') -eq '1') {
        $t += New-Target 'Windows Update download cache' @("$win\SoftwareDistribution\Download") @() @('wuauserv', 'bits')
    }
    if ((Get-Cfg 'Clean' 'BrowserCaches' '1') -eq '1') {
        $t += New-Target 'Chrome cache'  @("$lad\Google\Chrome\User Data\*\Cache", "$lad\Google\Chrome\User Data\*\Code Cache", "$lad\Google\Chrome\User Data\*\GPUCache") @('chrome')
        $t += New-Target 'Edge cache'    @("$lad\Microsoft\Edge\User Data\*\Cache", "$lad\Microsoft\Edge\User Data\*\Code Cache", "$lad\Microsoft\Edge\User Data\*\GPUCache") @('msedge')
        $t += New-Target 'Firefox cache' @("$lad\Mozilla\Firefox\Profiles\*\cache2") @('firefox')
    }
    if ((Get-Cfg 'Clean' 'Prefetch' '0') -eq '1')    { $t += New-Target 'Prefetch' @("$win\Prefetch") }
    if ((Get-Cfg 'Clean' 'RecycleBin' '0') -eq '1')  { $t += New-Target 'Recycle Bin' @() @() @() 'Recycle' }
    $t
}
function Measure-Targets($Targets) {
    foreach ($tg in $Targets) {
        if ($tg.Special -eq 'Recycle') { $tg.Size = Get-RecycleSize } else { $tg.Size = Get-DirSize $tg.Paths }
    }
}

function Invoke-Clean([switch]$Auto, [switch]$PreviewOnly) {
    Say '[+] Clean' Cyan
    if ($script:PreScan -and -not $PreviewOnly) {
        $targets = @($script:PreScan)      # reuse the preview scan from All-in-one
        $script:PreScan = $null
    } else {
        $targets = @(Get-CleanTargets)
        Working-Begin 'Scanning folders...'
        Measure-Targets $targets
        Working-End
    }
    $total = [int64]0
    foreach ($tg in $targets) {
        Say ('  {0,-34}{1,12}' -f $tg.Name, (Format-Size $tg.Size))
        $total += $tg.Size
    }
    Say ('  {0,-34}{1,12}' -f 'TOTAL', (Format-Size $total)) White
    if ($PreviewOnly) { $script:PreScan = $targets; return }
    if ($total -eq 0 -and (Get-Cfg 'Clean' 'ComponentCleanup' '0') -ne '1') { return }
    if (-not $script:DryRun -and -not $Auto -and -not (Ask '  Delete these files?')) { return }

    $freeBefore = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
    foreach ($tg in $targets) {
        if ($tg.Size -le 0) { continue }
        if ($tg.Special -eq 'Recycle') {
            if ($Auto) { Say '  [--]  Recycle Bin is never emptied automatically (use menu option 5)' DarkGray; continue }
            if (-not $script:DryRun -and -not (Ask "  Permanently empty the Recycle Bin ($(Format-Size $tg.Size))?")) { continue }
            Invoke-Act 'Empty Recycle Bin' { Clear-RecycleBin -Force -ErrorAction Stop }
            continue
        }
        if ($tg.Procs.Count -gt 0 -and -not (Confirm-CloseApps $tg.Procs "It must be closed to clean its cache ($(Format-Size $tg.Size)).")) {
            Say "  [--]  $($tg.Name) skipped (app left open)" DarkGray
            Write-Log "Clean $($tg.Name) skipped by choice"
            continue
        }
        $script:LastRmErrors = @()
        Invoke-Act "Clean $($tg.Name) ($(Format-Size $tg.Size))" {
            $stopped = @()
            foreach ($sn in $tg.Svcs) {
                $sv = Get-Service -Name $sn -ErrorAction SilentlyContinue
                if ($sv -and $sv.Status -eq 'Running') { Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue; $stopped += $sn }
            }
            foreach ($d in (Resolve-Dirs $tg.Paths)) {
                Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable rmEv
                $script:LastRmErrors += @($rmEv)
            }
            foreach ($sn in $stopped) { Start-Service -Name $sn -ErrorAction SilentlyContinue }
        }
        if ($script:LastRmErrors.Count -gt 0) {
            $names = ($script:LastRmErrors | Select-Object -First 3 | ForEach-Object { "$($_.TargetObject)" }) -join ' ; '
            # Files held open by running programs are normal: report quietly, not as a problem.
            Say "        $($script:LastRmErrors.Count) item(s) in use were left in place" DarkGray
            Write-Log "Clean $($tg.Name): $($script:LastRmErrors.Count) in-use items left. First: $names"
        }
    }
    if ((Get-Cfg 'Clean' 'ComponentCleanup' '0') -eq '1') {
        Invoke-Act 'Windows component cleanup (DISM, may take minutes)' {
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "DISM exit code $LASTEXITCODE" }
        }
    }
    Invoke-Act 'Flush DNS cache' { Clear-DnsClientCache }
    if (-not $script:DryRun) {
        $freeAfter = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free
        Say ('  Freed about {0}' -f (Format-Size ([math]::Max(0, $freeAfter - $freeBefore)))) Green
        Write-Log ('Clean freed {0}' -f (Format-Size ([math]::Max(0, $freeAfter - $freeBefore))))
    }
}

# ---------------------------------------------------------------- startup manager
function Get-StartupItems {
    $items = @()
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $keys) {
        if (Test-Path $k) {
            $p = Get-ItemProperty -Path $k
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                    $items += [pscustomobject]@{ Kind = 'RunKey'; Name = $prop.Name; Command = [string]$prop.Value; Location = $k }
                }
            }
        }
    }
    foreach ($f in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if ($f -and (Test-Path $f)) {
            Get-ChildItem -LiteralPath $f -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
                $items += [pscustomobject]@{ Kind = 'Folder'; Name = $_.Name; Command = $_.FullName; Location = $f }
            }
        }
    }
    $items
}
function Test-Protected([string]$Name) {
    foreach ($p in (Get-CfgList 'Startup' 'Protected')) { if ($Name -like "*$p*") { return $true } }
    return $false
}
function Invoke-StartupManager {
    Say '[+] Startup programs' Cyan
    $items = @(Get-StartupItems)
    if ($items.Count -eq 0) { Say '  No startup items found.'; return }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $flag = ''
        if (Test-Protected $it.Name) { $flag = '  (protected)' }
        $cmd = $it.Command
        if ($cmd.Length -gt 80) { $cmd = $cmd.Substring(0, 77) + '...' }
        Say ('{0,3}. {1}{2}' -f ($i + 1), $it.Name, $flag) White
        Say ('       {0}' -f $cmd) DarkGray
    }
    if ($script:AutoYes) { return }
    $sel = Read-Host 'Numbers to disable (1,3), or D + numbers to DELAY them instead (D2,5), Enter = none'
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $delay = $sel.Trim().ToUpper().StartsWith('D')
    $mins = 2
    if ($delay) {
        $sel = $sel.Trim().Substring(1)
        $mm = Read-Host 'Start them how many minutes after sign-in? [2]'
        if ($mm -match '^\d+$') { $mins = [int]$mm }
    }
    foreach ($tok in ($sel -split ',')) {
        $n = 0
        if (-not [int]::TryParse($tok.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) { Say "  Ignored: $tok" Yellow; continue }
        $it = $items[$n - 1]
        if (Test-Protected $it.Name) { Say "  [--]  $($it.Name) is protected, skipped" Yellow; continue }
        if ($delay) { Invoke-DelayStartup $it $mins; continue }
        Disable-StartupItem $it
    }
}
function Disable-StartupItem($it) {
    if ($it.Kind -eq 'RunKey') {
        Invoke-Act "Disable startup item $($it.Name)" {
            $val = (Get-ItemProperty -Path $it.Location -Name $it.Name).($it.Name)
            Add-Journal @{ Type = 'startup-runkey'; Location = $it.Location; Name = $it.Name; Value = [string]$val }
            Remove-ItemProperty -Path $it.Location -Name $it.Name -ErrorAction Stop
        }
    } else {
        Invoke-Act "Disable startup item $($it.Name)" {
            $dest = Join-Path $script:BackupDir 'startup'
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $bk = Join-Path $dest ((Get-Date -Format 'yyyyMMddHHmmss') + '_' + $it.Name)
            Add-Journal @{ Type = 'startup-file'; Original = $it.Command; Backup = $bk }
            Move-Item -LiteralPath $it.Command -Destination $bk -ErrorAction Stop
        }
    }
}
# Used by the graphical version: act on startup items chosen in its list (key = Kind|Location|Name).
function Invoke-StartupBatch([string]$Mode, [string[]]$Keys, [int]$Minutes = 2) {
    foreach ($it in @(Get-StartupItems)) {
        $key = "$($it.Kind)|$($it.Location)|$($it.Name)"
        if ($Keys -notcontains $key) { continue }
        if (Test-Protected $it.Name) { Say "  [--]  $($it.Name) is protected, skipped" Yellow; continue }
        if ($Mode -eq 'Delay') { Invoke-DelayStartup $it $Minutes } else { Disable-StartupItem $it }
    }
}

# ---------------------------------------------------------------- services
function Invoke-Services {
    Say '[+] Optional services' Cyan
    $hasHdd = $false
    try { $hasHdd = [bool](Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.MediaType -eq 'HDD' }) } catch {}
    foreach ($name in (Get-CfgList 'Services' 'Candidates')) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.StartMode -eq 'Disabled') {
            Say "  $name is already disabled" DarkGray
            if ($name -eq 'SysMain' -and $hasHdd -and ($script:DryRun -or -not $script:AutoYes)) {
                Say '    You have a hard drive: SysMain helps app launch speed there.' DarkYellow
                if ($script:DryRun -or (Ask '    Re-enable SysMain?')) {
                    Invoke-Act 'Re-enable SysMain' {
                        Add-Journal @{ Type = 'service'; Name = $name; StartMode = 'Disabled'; WasRunning = $false }
                        Set-Service -Name $name -StartupType Automatic -ErrorAction Stop
                        Start-Service -Name $name -ErrorAction SilentlyContinue
                    }
                }
            }
            continue
        }
        Say ('  {0} - {1}  [{2}, {3}]' -f $name, $svc.DisplayName, $svc.State, $svc.StartMode) White
        if ($name -eq 'SysMain') { Say '    Note: SysMain speeds up app launches on hard drives. Keep it there.' DarkYellow }
        if ($script:AutoYes -and -not $script:DryRun) { continue }
        if (-not (Ask "  Disable $name?")) { continue }
        $prevMode = [string]$svc.StartMode
        $wasRunning = ($svc.State -eq 'Running')
        Invoke-Act "Disable service $name" {
            Add-Journal @{ Type = 'service'; Name = $name; StartMode = $prevMode; WasRunning = $wasRunning }
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
        }
    }
}

# ---------------------------------------------------------------- turbo
# Older scripts created a new "Ultimate Performance" copy on every run. Remove the extra copies.
function Get-UltimateDuplicates {
    $active = $null
    if ("$(powercfg /getactivescheme)" -match $script:GuidRx) { $active = $Matches[0] }
    $keep = @($active)
    foreach ($e in @(Get-Journal)) { if ($e.Type -eq 'powerplan' -and $e.Previous) { $keep += [string]$e.Previous } }
    $dups = @()
    foreach ($ln in @(powercfg /list)) {
        if ($ln -match 'Ultimate' -and "$ln" -match $script:GuidRx) {
            $g = $Matches[0]
            if ($keep -notcontains $g) { $dups += $g }
        }
    }
    $dups
}
function Invoke-PlanCleanup {
    $dups = @(Get-UltimateDuplicates)
    if ($dups.Count -eq 0) { return }
    Say "  Found $($dups.Count) unused duplicate 'Ultimate Performance' power plans." DarkYellow
    if ($script:AutoYes -and -not $script:DryRun) { return }
    if (-not $script:DryRun -and -not (Ask '  Delete the duplicates (the active plan is kept)?')) { return }
    foreach ($g in $dups) { Invoke-Act "Delete duplicate power plan $g" { powercfg /delete $g; if ($LASTEXITCODE -ne 0) { throw 'powercfg /delete failed' } } }
}

function Invoke-Turbo {
    Say '[+] Turbo mode' Cyan
    $prev = $null
    if ("$(powercfg /getactivescheme)" -match $script:GuidRx) { $prev = $Matches[0] }
    $onBattery = $false
    try { $onBattery = (@(Get-CimInstance Win32_Battery -ErrorAction Stop | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0) } catch {}
    $skipPlan = $onBattery -and -not $script:DryRun -and -not (Ask '  This laptop is running on battery. A high-performance plan drains it faster. Apply anyway?')
    if ($skipPlan) {
        Say '  [--]  Power plan left unchanged (running on battery)' DarkGray
        Write-Log 'Power plan skipped: on battery'
    } elseif ("$(powercfg /getactivescheme)" -match 'Ultimate|High performance|8c5e7fda-e8bf|e9a42b02-d5df') {
        Say '  [OK]  Performance power plan already active' DarkGray
        Write-Log 'Power plan already performance, unchanged'
    } else {
    Invoke-Act 'Activate Ultimate/High performance power plan' {
        $plan = $null
        $ln = powercfg /list | Where-Object { $_ -match 'Ultimate' } | Select-Object -First 1
        if ("$ln" -match $script:GuidRx) { $plan = $Matches[0] }
        if (-not $plan) {
            $out = powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
            if ("$out" -match $script:GuidRx) { $plan = $Matches[0]; powercfg /changename $plan 'Turbo Ultimate Performance' | Out-Null }
        }
        if (-not $plan) { $plan = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        Add-Journal @{ Type = 'powerplan'; Previous = $prev }
        powercfg /setactive $plan
        if ($LASTEXITCODE -ne 0) { throw "powercfg could not activate $plan" }
    }
    }
    Invoke-PlanCleanup
    $cap = [int](Get-Cfg 'Turbo' 'DefenderCpuCap' '25')
    $curCap = $null
    try { $curCap = (Get-MpPreference -ErrorAction Stop).ScanAvgCPULoadFactor } catch {}
    if ($curCap -eq $cap) {
        Say "  [OK]  Defender scan CPU cap already $cap percent" DarkGray
        Write-Log 'Defender cap already set, unchanged'
    } else {
        Invoke-Act "Cap Defender scan CPU usage at $cap percent" {
            $old = (Get-MpPreference -ErrorAction Stop).ScanAvgCPULoadFactor
            Set-MpPreference -ScanAvgCPULoadFactor $cap -ErrorAction Stop
            Add-Journal @{ Type = 'defendercap'; Previous = $old }
        }
    }
}

# ---------------------------------------------------------------- disks
function Invoke-DiskOptimize([switch]$Auto) {
    Say '[+] Disk optimization' Cyan
    foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
        $l = [string]$v.DriveLetter
        $type = 'Unknown'
        try { $type = [string](Get-Partition -DriveLetter $l -ErrorAction Stop | Get-Disk | Get-PhysicalDisk).MediaType } catch {}
        # Windows already defrags hard drives on a schedule: only do it when it is really fragmented.
        if ($type -eq 'HDD' -and -not $script:DryRun) {
            Working-Begin "Analyzing fragmentation on ${l}: ..."
            $an = (defrag.exe "${l}:" /A 2>&1 | Out-String)
            Working-End
            if ($an -match 'fragmented space\s*=\s*(\d+)\s*%' -and [int]$Matches[1] -lt 10) {
                Say "  [--]  ${l}: ($type) only $($Matches[1]) percent fragmented, defrag not needed" DarkGray
                Write-Log "Defrag ${l}: skipped, $($Matches[1]) percent fragmented"
                continue
            }
        }
        Invoke-Act "Optimize ${l}: ($type) - TRIM on SSD, defrag on HDD" {
            defrag.exe "${l}:" /O | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "defrag exit code $LASTEXITCODE" }
        }
    }
    if ($Auto) { return }
    if ($script:DryRun -or (Ask '  Run a read-only online disk scan on the system drive (chkdsk /scan)?')) {
        Invoke-Act 'chkdsk /scan (read-only)' {
            $o = chkdsk.exe $env:SystemDrive /scan
            Write-Log (($o | Select-Object -Last 6) -join ' | ')
            if ($LASTEXITCODE -gt 1) { throw "chkdsk reported problems (exit code $LASTEXITCODE), see log" }
        }
    }
}

# ---------------------------------------------------------------- update / repair / debloat
# Which running processes block updating a package. Config [UpdateProcesses] overrides these defaults.
function Get-UpdateProcs($Pkg) {
    $defaults = @{
        'Microsoft.VisualStudioCode' = 'Code'
        'Microsoft.WindowsTerminal'  = 'WindowsTerminal'
        'Spotify.Spotify'            = 'Spotify'
        'Google.Chrome'              = 'chrome'
        'Mozilla.Firefox'            = 'firefox'
        'Microsoft.Edge'             = 'msedge'
        'Notepad++.Notepad++'        = 'notepad++'
        'VideoLAN.VLC'               = 'vlc'
    }
    $list = @()
    $cfg = Get-Cfg 'UpdateProcesses' $Pkg.Id ''
    if ($cfg) { $list = @($cfg -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    elseif ($defaults.ContainsKey($Pkg.Id)) { $list = @($defaults[$Pkg.Id]) }
    else {
        # Guess from the last part of the id, e.g. Foo.Bar -> process "Bar"
        $last = ($Pkg.Id -split '\.')[-1]
        if ($last -and (Get-Process -Name $last -ErrorAction SilentlyContinue)) { $list = @($last) }
    }
    return $list
}
function Invoke-Update {
    Say '[+] Software update (winget)' Cyan
    if (-not (Get-Command winget -ErrorAction SilentlyContinue) -and -not $script:DryRun) {
        Say '  [x]   winget not found. Install App Installer from the Microsoft Store.' Red
        Write-Log 'winget missing'
        Add-Problem 'Software update' 'winget was not found' 'Install "App Installer" from the Microsoft Store.'
        return
    }
    if ($script:DryRun) { Say '  [DRY] winget upgrade --all' DarkYellow; Write-Log '[DRY] Update'; return }
    # Upgrade one package at a time so a single failure is visible and cannot hide the others.
    $lines = @(winget upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String -Stream)
    $pkgs = @()
    foreach ($ln in $lines) {
        # Columns can touch each other, so read from the right: ... Id Version Available Source
        $tok = @($ln.Trim() -split '\s+')
        if ($tok.Count -ge 5 -and $tok[-1] -match '^(winget|msstore)$' -and $tok[-4] -match '^[\w\-+]+(\.[\w\-+]+)+$') {
            $pkgs += [pscustomobject]@{ Name = ($tok[0..($tok.Count - 5)] -join ' '); Id = $tok[-4] }
        }
    }
    if ($pkgs.Count -eq 0) { Say '  Everything is up to date.' Green; Write-Log 'winget: nothing to update'; return }
    Say "  $($pkgs.Count) update(s) available." White
    $failed = @()
    $skipped = @()
    $selfUpdating = @(Get-CfgList 'Update' 'SelfUpdating')
    if (-not $script:Cfg.ContainsKey('Update')) { $selfUpdating = @('Spotify.Spotify') }
    $uacOn = $false
    try { $uacOn = ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableLUA -eq 1) } catch {}
    $n = $pkgs.Count
    $k = 0
    foreach ($p in $pkgs) {
        $k++
        Say ('  {0} {1}/{2}  {3}' -f (Format-Bar ($k - 1) $n 16), $k, $n, $p.Name) White
        if ($selfUpdating -contains $p.Id) {
            Say '        [--]  updates itself when you open it (skipped on purpose)' DarkGray
            Write-Log "winget skip self-updating $($p.Id)"
            $skipped += $p.Name
            continue
        }
        $procs = @(Get-UpdateProcs $p)
        if ($procs.Count -gt 0 -and -not (Confirm-CloseApps $procs "It must be closed to update $($p.Name).")) {
            Say '        [--]  skipped (app left open)' DarkGray
            Write-Log "winget skipped by choice $($p.Id)"
            $skipped += $p.Name
            continue
        }
        Working-Begin "Updating $($p.Id) ..."
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $wout = @(winget upgrade --id $p.Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String -Stream | Where-Object { $_.Trim() -ne '' })
        $code = $LASTEXITCODE
        Working-End
        $wtail = (($wout | Select-Object -Last 4) -join ' / ')
        $hex = '0x{0:X8}' -f [uint32]($code -band 0xFFFFFFFFL)
        $dur = Format-Duration $sw.Elapsed
        if ($code -eq 0) { Say "        [OK]  updated  ($dur)" Green; Write-Log "winget OK $($p.Id)"; $script:OkCount++ }
        elseif ($code -eq -1978335189) { Say '        [--]  no applicable update' DarkGray; Write-Log "winget n/a $($p.Id)" }
        elseif ($hex -eq '0x8A150056') {
            # The installer refuses to run elevated. With UAC on we can retry as a normal user.
            if ($uacOn) {
                Working-Begin "Retrying $($p.Id) as a normal user ..."
                $r = Invoke-Unelevated ("winget upgrade --id $($p.Id) --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity")
                Working-End
                if ($r.ExitCode -eq 0) { Say "        [OK]  updated as a normal user  ($dur)" Green; Write-Log "winget OK (unelevated) $($p.Id)"; $script:OkCount++ }
                else {
                    $tail = (($r.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / ')
                    Say "        [x]   failed as a normal user, code $($r.ExitCode)" Red
                    $failed += $p.Name
                    Add-Problem "Update $($p.Name)" "Normal-user retry failed (code $($r.ExitCode))" "Id $($p.Id). Output: $tail"
                }
            } else {
                Say '        [--]  cannot be updated from here (UAC is off, every window is admin)' DarkGray
                Write-Log "winget cannot run unelevated (UAC off) $($p.Id)"
                $skipped += $p.Name
            }
        }
        else {
            Say "        [x]   failed, code $hex  ($dur)" Red
            Write-Log ('winget FAIL {0} code {1}' -f $p.Id, $code)
            $failed += $p.Name
            Add-Problem "Update $($p.Name)" "winget exit code $hex" "Id $($p.Id). Last output: $wtail"
        }
    }
    Say ('  {0} {1}/{1}  done' -f (Format-Bar $n $n 16), $n) Cyan
    if ($failed.Count -gt 0) { Say ('  Failed: ' + ($failed -join ', ')) Yellow }
    if ($skipped.Count -gt 0) { Say ('  Skipped: ' + ($skipped -join ', ')) DarkGray }
}
function Invoke-Repair {
    Say '[+] System repair (DISM then SFC)' Cyan
    if ($script:DryRun) { Say '  [DRY] DISM /RestoreHealth, sfc /scannow' DarkYellow; Write-Log '[DRY] Repair'; return }
    Dism.exe /Online /Cleanup-Image /RestoreHealth
    $dc = $LASTEXITCODE
    Write-Log "DISM exit code $dc"
    if ($dc -ne 0) { Add-Problem 'DISM RestoreHealth' "Exit code $dc" 'Details: C:\Windows\Logs\DISM\dism.log' }
    sfc.exe /scannow
    $sc = $LASTEXITCODE
    Write-Log "SFC exit code $sc"
    if ($sc -ne 0) { Add-Problem 'SFC scannow' "Exit code $sc" 'Details: findstr /c:"[SR]" %windir%\Logs\CBS\CBS.log' }
}
function Invoke-Debloat([switch]$Auto) {
    Say '[+] Debloat' Cyan
    $apps = @(Get-CfgList 'Debloat' 'Apps')
    if (-not $Auto) {
        foreach ($o in (Get-CfgList 'Debloat' 'Optional')) {
            if (Ask "  Also remove optional app $o ?") { $apps += $o }
        }
    }
    $backup = Join-Path $script:Dir 'appx_backup_before_debloat.txt'
    Invoke-Act "Save installed app list to $backup" {
        Get-AppxPackage | Select-Object Name, PackageFullName | Sort-Object Name | Out-File -FilePath $backup -Encoding UTF8
    }
    foreach ($app in $apps) {
        $pk = @(Get-AppxPackage -Name $app -ErrorAction SilentlyContinue)
        if ($pk.Count -eq 0) { Say "  $app is not installed" DarkGray; continue }
        Invoke-Act "Remove $app" {
            Add-Journal @{ Type = 'appx'; Name = $app; PackageFullName = $pk[0].PackageFullName }
            $pk | Remove-AppxPackage -ErrorAction Stop
        }
    }
}

# ---------------------------------------------------------------- revert
function Invoke-Revert {
    Say '[+] Revert recorded changes' Cyan
    $j = @(Get-Journal)
    if ($j.Count -eq 0) { Say '  Nothing recorded to revert.'; return }
    foreach ($e in $j) {
        $what = switch ($e.Type) {
            'powerplan'      { "restore power plan $($e.Previous)" }
            'defendercap'    { "restore Defender CPU cap to $($e.Previous)" }
            'service'        { "restore service $($e.Name) to $($e.StartMode)" }
            'startup-runkey' { "restore startup item $($e.Name)" }
            'startup-file'   { "restore startup file $($e.Original)" }
            'appx'           { "app $($e.Name) was removed (reinstall from the Microsoft Store)" }
            'netpower'       { "re-enable power saving on adapter $($e.Name)" }
            'powersetting'   { "restore power-plan setting $($e.Setting)" }
            'pnp-disabled'   { "re-enable device $($e.Name)" }
            'wifi-auto'      { "auto-connect back on for Wi-Fi '$($e.Name)'" }
            'defender-policy' { "remove Defender policy $($e.Name)" }
            'defender-prefs' { 'turn Defender protection settings back on' }
            'defender-task'  { "enable Defender task $($e.Name)" }
            default          { Describe-ExtraEntry $e }
        }
        Say ('  {0}  {1}' -f $e.Time, $what)
    }
    if (-not $script:DryRun -and -not (Ask 'Revert all of these (newest first)?')) { return }
    $failed = @()
    for ($i = $j.Count - 1; $i -ge 0; $i--) {
        $e = $j[$i]
        $ok = $true
        if ($script:DryRun) { Say "  [DRY] revert $($e.Type) $($e.Name)" DarkYellow; continue }
        try {
            switch ($e.Type) {
                'powerplan' {
                    if ($e.Previous) { powercfg /setactive $e.Previous; if ($LASTEXITCODE -ne 0) { throw 'powercfg failed' } }
                }
                'defendercap' { Set-MpPreference -ScanAvgCPULoadFactor ([int]$e.Previous) -ErrorAction Stop }
                'service' {
                    $mode = switch ($e.StartMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Manual' } }
                    Set-Service -Name $e.Name -StartupType $mode -ErrorAction Stop
                    if ($e.WasRunning) { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
                }
                'startup-runkey' { Set-ItemProperty -Path $e.Location -Name $e.Name -Value $e.Value -ErrorAction Stop }
                'startup-file'   { Move-Item -LiteralPath $e.Backup -Destination $e.Original -ErrorAction Stop }
                'appx'           { Say "  Reinstall $($e.Name) from the Microsoft Store (cannot be automated)." Yellow }
                'netpower'       { Set-NetAdapterPowerManagement -Name $e.Name -AllowComputerToTurnOffDevice Enabled -ErrorAction Stop }
                'powersetting'   { Set-PowerIndex $e.Sub $e.Setting $e.AC $e.DC }
                'pnp-disabled'   { Enable-PnpDevice -InstanceId $e.InstanceId -Confirm:$false -ErrorAction Stop }
                'wifi-auto'      { netsh wlan set profileparameter name="$($e.Name)" connectionmode=auto | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'netsh failed' } }
                'defender-policy' { Undo-DefenderEntry $e }
                'defender-prefs' { Undo-DefenderEntry $e }
                'defender-task'  { Undo-DefenderEntry $e }
                default          { Undo-ExtraEntry $e }
            }
            Say "  [OK]  reverted $($e.Type) $($e.Name)" Green
            Write-Log "REVERT OK $($e.Type) $($e.Name)"
        } catch {
            $ok = $false
            Say "  [x]   could not revert $($e.Type) $($e.Name): $($_.Exception.Message)" Red
            Write-Log "REVERT FAIL $($e.Type) $($e.Name): $($_.Exception.Message)"
            Add-ErrorRecord "Revert $($e.Type) $($e.Name)" $_
        }
        if (-not $ok) { $failed += $e }
    }
    if ($script:DryRun) { return }
    if ($failed.Count -eq 0) {
        $arch = Join-Path $script:Dir ('turbo_undo_{0}.done.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))
        Move-Item -LiteralPath $script:Journal -Destination $arch -Force
    } else {
        Save-Journal $failed
        Say '  Failed items stay in the journal for another try.' Yellow
    }
}

# ---------------------------------------------------------------- diagnose
function Invoke-Diagnose {
    Say '== DIAGNOSIS (read-only) ==' Cyan
    $m = Get-Metrics
    $os = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $total = $sysDrive.Used + $sysDrive.Free
    $freePct = [math]::Round(($sysDrive.Free / $total) * 100, 1)
    Say ('  System drive free : {0} GB ({1} percent)' -f $m.FreeGB, $freePct)
    Say ('  RAM in use        : {0} percent' -f $m.RamUsedPct)
    Say ('  Processes         : {0}' -f $m.Processes)
    Say ('  Startup items     : {0}' -f $m.StartupItems)
    if ($m.LastBootSec) { Say ('  Last boot time    : {0} s' -f $m.LastBootSec) }
    Say ('  Uptime            : {0:N1} days' -f $uptime.TotalDays)

    $rec = @()
    $targets = @(Get-CleanTargets)
    Measure-Targets $targets
    $junk = [int64]0
    foreach ($tg in $targets) { $junk += $tg.Size }
    if ($junk -gt 500MB) { $rec += "5  Clean: about $(Format-Size $junk) of removable files" }
    if ($freePct -lt 15) { $rec += '5  System drive is nearly full (under 15 percent free)' }
    if ($m.StartupItems -gt 8) { $rec += "10 Startup manager: $($m.StartupItems) programs start with Windows" }
    $svcs = @()
    foreach ($n in (Get-CfgList 'Services' 'Candidates')) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($s -and $s.StartMode -ne 'Disabled' -and $n -ne 'SysMain') { $svcs += $n }
    }
    if ($svcs.Count -gt 0) { $rec += "11 Optional services still enabled: $($svcs -join ', ')" }
    if ("$(powercfg /getactivescheme)" -notmatch 'Ultimate|High|Performance') { $rec += '9  Power plan is not a performance plan' }
    $hdd = $false
    try { $hdd = [bool](Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.MediaType -eq 'HDD' }) } catch {}
    if ($hdd) { $rec += '7  Hard drive present: defrag helps; keep SysMain enabled' } else { $rec += '7  Run disk optimization (TRIM) now and then' }
    $bloat = @()
    foreach ($a in (Get-CfgList 'Debloat' 'Apps')) { if (Get-AppxPackage -Name $a -ErrorAction SilentlyContinue) { $bloat += $a } }
    if ($bloat.Count -gt 0) { $rec += "8  Debloat: $($bloat.Count) listed apps are installed" }
    $sm = Get-CimInstance Win32_Service -Filter "Name='SysMain'" -ErrorAction SilentlyContinue
    if ($hdd -and $sm -and $sm.StartMode -eq 'Disabled') { $rec += '11 SysMain is disabled but you have a hard drive: re-enable it (slower app launches otherwise)' }
    $wa = Get-WifiAdapter
    if ($wa) {
        $pm = Get-NetAdapterPowerManagement -Name $wa.Name -ErrorAction SilentlyContinue
        if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') { $rec += '15 Wi-Fi: Windows may power the adapter off (causes hangs); use Disable power saving' }
    }
    $usbs = Get-PowerIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    if ($usbs.AC -ne 0 -or $usbs.DC -ne 0) { $rec += '15 USB selective suspend is on: can freeze a USB Bluetooth adapter' }
    $np = @(Get-WifiProfiles).Count
    if ($np -gt 15) { $rec += "15 $np saved Wi-Fi networks: Windows may keep trying old ones; stop auto-connect on those you do not use" }
    $pending = $false
    foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) { if (Test-Path $rk) { $pending = $true } }
    if ($pending) { $rec += 'Restart: Windows has a restart pending (an update or install is unfinished)' }
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            if ("$($pd.HealthStatus)" -ne 'Healthy') { $rec += "7  Disk '$($pd.FriendlyName)' reports health: $($pd.HealthStatus). Back up your data" }
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($rc -and $rc.Wear -and [int]$rc.Wear -gt 80) { $rec += "7  Disk '$($pd.FriendlyName)' is $($rc.Wear) percent worn" }
            if ($rc -and $rc.Temperature -and [int]$rc.Temperature -gt 55) { $rec += "7  Disk '$($pd.FriendlyName)' is hot ($($rc.Temperature) C)" }
        }
    } catch {}
    try {
        if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableLUA -eq 0) {
            $rec += 'Security: UAC is OFF (every program runs as admin without asking). Turn it on in Control Panel > User Accounts > Change User Account Control settings'
        }
    } catch {}
    if ($uptime.TotalDays -gt 7) { $rec += 'Restart: Fast Startup keeps the kernel running; "Restart" (not Shut down) gives a clean state' }
    if ($m.RamUsedPct -gt 85) { $rec += 'RAM use is high; check what is running (Task Manager)' }

    Say ''
    Say 'Recommendations (menu number first):' White
    if ($rec.Count -eq 0) { Say '  Nothing urgent.' Green }
    foreach ($r in $rec) { Say "  - $r" Yellow }
    Write-Log "Diagnose: $($rec.Count) recommendations"
}

# ---------------------------------------------------------------- wifi / bluetooth fixes
function Get-WifiAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' } |
        Select-Object -First 1
}
function Get-BtRadio {
    Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^(USB|PCI)\\' } | Select-Object -First 1
}
# Reads an AC/DC power-plan value of the active scheme. Returns $null when it cannot be parsed.
function Get-PowerIndex([string]$Sub, [string]$Setting) {
    $o = "$(powercfg /query SCHEME_CURRENT $Sub $Setting 2>$null)"
    $ac = $null; $dc = $null
    if ($o -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $ac = [Convert]::ToInt32($Matches[1], 16) }
    if ($o -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $dc = [Convert]::ToInt32($Matches[1], 16) }
    [pscustomobject]@{ AC = $ac; DC = $dc }
}
function Set-PowerIndex([string]$Sub, [string]$Setting, $AC, $DC) {
    if ($null -ne $AC) { powercfg /setacvalueindex SCHEME_CURRENT $Sub $Setting $AC | Out-Null }
    if ($null -ne $DC) { powercfg /setdcvalueindex SCHEME_CURRENT $Sub $Setting $DC | Out-Null }
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

function Invoke-WifiReset {
    Say '[+] Wi-Fi quick reset (fixes stuck or stale connections)' Cyan
    $w = Get-WifiAdapter
    if (-not $w) { Say '  No Wi-Fi adapter found.' Yellow; return }
    Say "  Adapter: $($w.InterfaceDescription)"
    if (-not $script:DryRun -and -not $script:AutoYes -and -not (Ask '  Wi-Fi will drop for a few seconds. Continue?')) { return }
    Invoke-Act 'Restart WLAN AutoConfig service' { Restart-Service -Name WlanSvc -Force -ErrorAction Stop }
    Invoke-Act "Restart adapter $($w.Name)" { Restart-NetAdapter -Name $w.Name -Confirm:$false -ErrorAction Stop }
    Invoke-Act 'Flush DNS and ARP caches' { Clear-DnsClientCache; netsh interface ip delete arpcache | Out-Null }
}

function Invoke-BluetoothReset {
    Say '[+] Bluetooth + audio quick reset (fixes connected but no sound)' Cyan
    $r = Get-BtRadio
    if (-not $r) { Say '  No Bluetooth radio found.' Yellow; return }
    Say "  Radio: $($r.FriendlyName)"
    if (-not $script:DryRun -and -not $script:AutoYes -and -not (Ask '  Bluetooth devices will disconnect for a few seconds. Continue?')) { return }
    Invoke-Act 'Restart Bluetooth Support service' { Restart-Service -Name bthserv -Force -ErrorAction Stop }
    Invoke-Act 'Restart Bluetooth Audio Gateway service' { Restart-Service -Name BTAGService -Force -ErrorAction SilentlyContinue }
    Invoke-Act 'Restart Windows Audio services' {
        Restart-Service -Name AudioEndpointBuilder -Force -ErrorAction Stop
        Start-Service -Name AudioSrv -ErrorAction SilentlyContinue
    }
    Invoke-Act "Reset Bluetooth radio ($($r.FriendlyName))" {
        try { Disable-PnpDevice -InstanceId $r.InstanceId -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 3 }
        finally { Enable-PnpDevice -InstanceId $r.InstanceId -Confirm:$false -ErrorAction Stop }
    }
}

# Permanent fix for random hangs: stop Windows from powering Wi-Fi / USB Bluetooth down to save energy.
function Invoke-PowerSavingFix {
    Say '[+] Disable power saving on Wi-Fi and USB/Bluetooth' Cyan
    $w = Get-WifiAdapter
    if ($w) {
        $pm = Get-NetAdapterPowerManagement -Name $w.Name -ErrorAction SilentlyContinue
        if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -eq 'Enabled') {
            Invoke-Act "Stop Windows turning off $($w.Name) to save power" {
                Add-Journal @{ Type = 'netpower'; Name = $w.Name }
                Set-NetAdapterPowerManagement -Name $w.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
            }
        } else { Say "  $($w.Name): adapter power-off already disabled or unsupported" DarkGray }
    }
    $settings = @(
        @{ Label = 'Wireless adapter power saving = maximum performance'; Sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Set = '12bbebe6-58d6-4636-95bb-3217ef867c1a' },
        @{ Label = 'USB selective suspend = disabled (keeps USB Bluetooth awake)'; Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' }
    )
    foreach ($s in $settings) {
        $cur = Get-PowerIndex $s.Sub $s.Set
        if ($cur.AC -eq 0 -and $cur.DC -eq 0) { Say "  Already set: $($s.Label)" DarkGray; continue }
        Invoke-Act $s.Label {
            Add-Journal @{ Type = 'powersetting'; Sub = $s.Sub; Setting = $s.Set; AC = $cur.AC; DC = $cur.DC }
            Set-PowerIndex $s.Sub $s.Set 0 0
        }
    }
}

# Headphones that connect but stay silent are usually stuck on the "Hands-Free" (call) profile.
function Invoke-BluetoothNoSoundFix {
    Say '[+] Bluetooth no-sound fix (disable Hands-Free call-mode audio)' Cyan
    $hf = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'BTHHFENUM\BTHHFPAUDIO\*' -and $_.Status -eq 'OK' })
    if ($hf.Count -eq 0) { Say '  No Hands-Free audio devices found.'; return }
    foreach ($d in $hf) { Say "  - $($d.FriendlyName)" White }
    Say '  Effect: headphones always use stereo (A2DP). Their built-in microphone will not work on this PC.' DarkYellow
    Say '  Undo anytime with menu option 20.' DarkYellow
    if (-not $script:DryRun -and -not (Ask '  Disable these devices?')) { return }
    foreach ($d in $hf) {
        Invoke-Act "Disable $($d.FriendlyName)" {
            Add-Journal @{ Type = 'pnp-disabled'; InstanceId = $d.InstanceId; Name = $d.FriendlyName }
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
        }
    }
}

function Get-WifiProfiles {
    # Read the profile files instead of parsing netsh text, so it works on every Windows language.
    $names = @()
    $dir = Join-Path $env:ProgramData 'Microsoft\Wlan\Profiles\Interfaces'
    foreach ($f in @(Get-ChildItem -Path $dir -Recurse -Filter *.xml -ErrorAction SilentlyContinue)) {
        try { $x = New-Object System.Xml.XmlDocument; $x.Load($f.FullName); if ($x.WLANProfile.name) { $names += [string]$x.WLANProfile.name } } catch {}
    }
    return @($names | Sort-Object -Unique)
}
function Invoke-WifiProfiles {
    Say '[+] Saved Wi-Fi networks' Cyan
    $profiles = @(Get-WifiProfiles)
    if ($profiles.Count -eq 0) { Say '  None found.'; return }
    for ($i = 0; $i -lt $profiles.Count; $i++) { Say ('{0,3}. {1}' -f ($i + 1), $profiles[$i]) }
    if ($script:AutoYes) { return }
    Say '  A = stop auto-connecting to chosen networks (reversible)   D = forget chosen networks (password is lost)' DarkYellow
    $mode = (Read-Host 'A / D / Enter = cancel').Trim().ToUpper()
    if ($mode -ne 'A' -and $mode -ne 'D') { return }
    $sel = Read-Host 'Numbers (comma separated)'
    foreach ($tok in ($sel -split ',')) {
        $n = 0
        if (-not [int]::TryParse($tok.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $profiles.Count) { continue }
        $name = $profiles[$n - 1]
        if ($mode -eq 'A') {
            Invoke-Act "Stop auto-connect to '$name'" {
                netsh wlan set profileparameter name="$name" connectionmode=manual | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'netsh failed (unusual characters in the name?)' }
                Add-Journal @{ Type = 'wifi-auto'; Name = $name }
            }
        } elseif (Ask "  Forget '$name' permanently?") {
            Invoke-Act "Forget '$name'" {
                netsh wlan delete profile name="$name" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'netsh failed (unusual characters in the name?)' }
            }
        }
    }
}

function Invoke-NetDeepReset {
    Say '[+] Deep network reset (Winsock + TCP/IP)' Cyan
    Say '  Rebuilds the network stack. Needs a restart. Cannot be undone from this tool.' DarkYellow
    if (-not $script:DryRun -and -not (Ask '  Continue?')) { return }
    Invoke-Act 'netsh winsock reset' { netsh winsock reset | Out-Null }
    Invoke-Act 'netsh int ip reset' { netsh int ip reset | Out-Null }
    Invoke-Act 'Flush DNS' { Clear-DnsClientCache }
    if (-not $script:DryRun) { Say '  Restart Windows to finish.' Yellow }
}

function Invoke-NetFixMenu {
    if ($script:AutoYes) {
        Invoke-WifiReset; Invoke-BluetoothReset; Invoke-PowerSavingFix; Invoke-BluetoothNoSoundFix; Invoke-WifiProfiles; Invoke-NetDeepReset
        return
    }
    while ($true) {
        Say ''
        Say '[ WI-FI / BLUETOOTH FIXES ]' Cyan
        Say '  A. Wi-Fi quick reset              (stuck / stale connection)'
        Say '  B. Bluetooth + audio quick reset  (connected but no sound)'
        Say '  C. Disable power saving           (permanent fix for random hangs)'
        Say '  D. No-sound fix                   (disable Hands-Free call-mode audio)'
        Say '  E. Saved Wi-Fi networks           (stop auto-connect / forget)'
        Say '  F. Deep network reset             (needs restart)'
        Say '  0. Back'
        switch ((Read-Host '>> Select').Trim().ToUpper()) {
            'A' { Invoke-WifiReset }
            'B' { Invoke-BluetoothReset }
            'C' { Invoke-PowerSavingFix }
            'D' { Invoke-BluetoothNoSoundFix }
            'E' { Invoke-WifiProfiles }
            'F' { Invoke-NetDeepReset }
            '0' { return }
        }
    }
}

# ================================================================ DOCTOR: find problems, then fix them
$script:Findings = New-Object System.Collections.ArrayList
$script:AckFile = Join-Path $script:Dir 'turbo_acks.json'
$script:HealthFile = Join-Path $script:Dir 'turbo_health.json'
$script:HealthReport = Join-Path $script:Dir 'turbo_health_report.txt'
$script:WuSoftware = @()
$script:WuDrivers = @()
$script:NeedReboot = $false

function Add-Finding([string]$Id, [string]$Sev, [string]$Title, [string]$Detail, [string]$Fix = '', $FixArg = $null, [string]$Download = '', [string]$AckKey = '') {
    [void]$script:Findings.Add([pscustomobject]@{ Id = $Id; Sev = $Sev; Title = $Title; Detail = $Detail; Fix = $Fix; FixArg = $FixArg; Download = $Download; AckKey = $AckKey })
}
# "Acknowledged" event groups: after a fix (or Ignore) older events no longer raise the same finding.
function Get-Acks {
    $h = @{}
    if (Test-Path $script:AckFile) {
        try {
            $o = Get-Content $script:AckFile -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [datetime]$p.Value }
        } catch {}
    }
    return $h
}
function Set-Ack([string]$Key) {
    if (-not $Key -or $script:DryRun) { return }
    $h = Get-Acks
    $h[$Key] = Get-Date
    $o = @{}
    foreach ($k in $h.Keys) { $o[$k] = $h[$k].ToString('o') }
    $o | ConvertTo-Json | Set-Content -Path $script:AckFile -Encoding UTF8
}
function Write-Wrapped([string]$Text, [int]$Indent = 7, [int]$Width = 80, [string]$Color = 'Gray') {
    $line = ''
    foreach ($w in ($Text -split '\s+')) {
        if (-not $w) { continue }
        if (($line.Length + $w.Length + 1) -gt $Width -and $line) { Say ((' ' * $Indent) + $line) $Color; $line = $w }
        elseif ($line) { $line += ' ' + $w }
        else { $line = $w }
    }
    if ($line) { Say ((' ' * $Indent) + $line) $Color }
}

# Runtime libraries: which winget package provides which DLLs.
$script:RtVc2015 = @('Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86')
$script:RtVc2013 = @('Microsoft.VCRedist.2013.x64', 'Microsoft.VCRedist.2013.x86')
$script:RtVc2012 = @('Microsoft.VCRedist.2012.x64', 'Microsoft.VCRedist.2012.x86')
$script:RtVc2010 = @('Microsoft.VCRedist.2010.x64', 'Microsoft.VCRedist.2010.x86')
$script:RtDx = @('Microsoft.DirectX')
function Get-RuntimeForModule([string]$Mod) {
    $m = $Mod.ToLower()
    if ($m -match '^(vcruntime140|msvcp140|concrt140|vccorlib140|mfc140)') { return @{ Name = 'Visual C++ 2015-2022 Redistributable'; Ids = $script:RtVc2015 } }
    if ($m -match '^(msvcr|msvcp|mfc)120') { return @{ Name = 'Visual C++ 2013 Redistributable'; Ids = $script:RtVc2013 } }
    if ($m -match '^(msvcr|msvcp|mfc)110') { return @{ Name = 'Visual C++ 2012 Redistributable'; Ids = $script:RtVc2012 } }
    if ($m -match '^(msvcr|msvcp|mfc)100') { return @{ Name = 'Visual C++ 2010 Redistributable'; Ids = $script:RtVc2010 } }
    if ($m -match '^(d3dx9_|d3dx10_|d3dx11_|xinput1_|x3daudio|xaudio2_)') { return @{ Name = 'DirectX End-User Runtime'; Ids = $script:RtDx } }
    return $null
}

# ---------------------------------------------------------------- scanners (read-only)
function Scan-System {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    if ($os.Caption -match 'Windows 10') {
        $d = 'Windows 10 stopped getting free security updates on 14 Oct 2025. Open Settings > Update & Security > Windows Update and look for an Extended Security Updates (ESU) enrollment link. Microsoft''s ESU end date has been reported differently, so check microsoft.com for the current one.'
        if ($cpu -match 'i[3579]-(\d{1,2})\d{3}') {
            $gen = [int]$Matches[1]
            if ($gen -lt 8) { $d += " This CPU is generation $gen and Windows 11 officially needs generation 8 or newer, so upgrading is not supported on this PC." }
        }
        Add-Finding 'os-eol' 'MED' 'Windows 10 is out of support' $d
    }
    $pending = $false
    foreach ($rk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) { if (Test-Path $rk) { $pending = $true } }
    if ($pending) { Add-Finding 'reboot' 'MED' 'A restart is pending' 'An update or install is not finished until you restart Windows.' 'Restart' }
    try {
        if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableLUA -eq 0) {
            Add-Finding 'uac-off' 'MED' 'User Account Control (UAC) is turned off' 'Every program runs with full admin rights without asking, so malware can change the system silently, and some installers (Spotify) refuse to run. Turning it on needs a restart; afterwards programs that need admin rights will show a confirmation prompt.' 'UacOn'
        }
    } catch {}
    $c = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $pct = 100 * $c.Free / ($c.Free + $c.Used)
    if ($pct -lt 10) {
        Add-Finding 'lowspace' 'HIGH' ('System drive is almost full ({0:N1} GB free, {1:N0} percent)' -f ($c.Free / 1GB), $pct) 'A nearly full drive makes Windows slow and blocks updates. Clean files, move big files, or uninstall apps you do not use.' 'Clean'
    }
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            if ("$($pd.HealthStatus)" -ne 'Healthy') { Add-Finding "disk-$($pd.FriendlyName)" 'HIGH' "Disk '$($pd.FriendlyName)' reports health: $($pd.HealthStatus)" 'The drive may be failing. Back up your data now.' }
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($rc -and $rc.Wear -and [int]$rc.Wear -gt 80) { Add-Finding "wear-$($pd.FriendlyName)" 'MED' "Disk '$($pd.FriendlyName)' is $($rc.Wear) percent worn" 'Plan to replace it and keep backups.' }
        }
    } catch {}
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if (-not $mp.AMRunningMode -or "$($mp.AMRunningMode)" -eq 'Normal') {
            if (-not $mp.RealTimeProtectionEnabled) { Add-Finding 'av-rt' 'HIGH' 'Defender real-time protection is off' 'Turn it on in Windows Security > Virus and threat protection. Not changed automatically because it is a security setting.' }
            $age = ((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays
            if ($age -gt 7) { Add-Finding 'av-sig' 'MED' ('Antivirus definitions are {0:N0} days old' -f $age) 'Defender cannot catch new threats with old definitions.' 'DefenderSigs' $null 'definition update from Microsoft' }
        }
    } catch {}
    # Maker's own update tool: the best source for BIOS, chipset and device drivers.
    if ($script:Plat -and -not $script:Plat.VM -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $tool = $null
        if ($script:Plat.Vendor -match 'Dell') { $tool = @('Dell.CommandUpdate', 'Dell Command | Update') }
        elseif ($script:Plat.Vendor -match 'LENOVO') { $tool = @('Lenovo.SystemUpdate', 'Lenovo System Update') }
        if ($tool) {
            winget list --id $tool[0] --exact --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Add-Finding "vendor-$($tool[0])" 'INFO' "$($tool[1]) is not installed" "It checks your $($script:Plat.Vendor) PC for BIOS, firmware and driver updates that Windows Update does not offer. Very old models may have no updates left." 'InstallRuntime' @($tool[0]) 'from the vendor through winget'
            }
        }
    }
    foreach ($n in 'EventLog', 'Winmgmt', 'Dhcp', 'Dnscache', 'AudioSrv', 'AudioEndpointBuilder', 'WlanSvc', 'BFE', 'RpcSs', 'Schedule', 'Themes') {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($s -and $s.StartMode -eq 'Auto' -and $s.State -ne 'Running') {
            Add-Finding "svc-$n" 'MED' "Service '$($s.DisplayName)' should be running but is stopped" 'Windows features that depend on it will misbehave.' 'ServiceStart' $n
        }
    }
}

function Scan-Updates {
    $script:WuSoftware = @()
    $script:WuDrivers = @()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $res = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
    } catch {
        Add-Finding 'wu-fail' 'MED' 'Could not ask Windows Update for updates' "$($_.Exception.Message) Resetting the Windows Update components usually fixes this." 'ResetWU'
        return
    }
    foreach ($u in $res.Updates) { if ($u.Type -eq 2) { $script:WuDrivers += $u } else { $script:WuSoftware += $u } }
    if ($script:WuSoftware.Count -gt 0) {
        $mb = [math]::Round((($script:WuSoftware | Measure-Object MaxDownloadSize -Sum).Sum) / 1MB)
        $titles = ($script:WuSoftware | Select-Object -First 4 | ForEach-Object { $_.Title }) -join '; '
        Add-Finding 'wu-sw' 'HIGH' "$($script:WuSoftware.Count) Windows update(s) waiting" $titles 'InstallWU' 'Software' "about $mb MB from Windows Update"
    }
    if ($script:WuDrivers.Count -gt 0) {
        $mb = [math]::Round((($script:WuDrivers | Measure-Object MaxDownloadSize -Sum).Sum) / 1MB)
        $titles = ($script:WuDrivers | Select-Object -First 4 | ForEach-Object { $_.Title }) -join '; '
        Add-Finding 'wu-drv' 'MED' "$($script:WuDrivers.Count) driver update(s) available" $titles 'InstallWU' 'Driver' "about $mb MB from Windows Update"
    }
}

function Scan-Devices {
    $meaning = @{
        1 = 'not configured correctly'; 3 = 'driver or memory problem'; 10 = 'cannot start'; 12 = 'resource conflict'; 14 = 'needs a restart'
        18 = 'drivers need reinstalling'; 19 = 'registry problem'; 24 = 'not present, not working, or missing drivers'; 28 = 'no driver installed'
        31 = 'not working properly'; 32 = 'driver disabled'; 37 = 'driver failed to start'; 39 = 'driver is corrupt or missing'; 41 = 'driver loaded but hardware not found'
        43 = 'Windows stopped it after it reported problems'; 48 = 'blocked by Windows'; 52 = 'driver is not signed'
    }
    $mine = @()
    foreach ($e in @(Get-Journal)) { if ($e.Type -eq 'pnp-disabled') { $mine += [string]$e.InstanceId } }
    foreach ($d in @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue)) {
        $code = [int]$d.ConfigManagerErrorCode
        if ($code -eq 22 -or $code -eq 45) { continue }      # disabled on purpose / not plugged in
        if ($mine -contains $d.PNPDeviceID) { continue }
        $why = $meaning[$code]
        if (-not $why) { $why = 'unknown problem' }
        Add-Finding "dev-$($d.PNPDeviceID)" 'MED' "Device problem: $($d.Name)" "Windows error code ${code}: $why. A rescan may fix it. If not, get the driver from the PC maker ($(Get-VendorSite)) or Windows Update." 'ScanDevices'
    }
}

function Scan-Runtimes {
    if (-not [Environment]::Is64BitOperatingSystem) { return }
    $win = $env:SystemRoot
    $checks = @(
        @{ N = 'Visual C++ 2015-2022 (64-bit)'; F = @('System32\vcruntime140.dll', 'System32\msvcp140.dll'); Ids = @('Microsoft.VCRedist.2015+.x64') },
        @{ N = 'Visual C++ 2015-2022 (32-bit)'; F = @('SysWOW64\vcruntime140.dll', 'SysWOW64\msvcp140.dll'); Ids = @('Microsoft.VCRedist.2015+.x86') },
        @{ N = 'Visual C++ 2013 (64-bit)'; F = @('System32\msvcr120.dll'); Ids = @('Microsoft.VCRedist.2013.x64') },
        @{ N = 'Visual C++ 2013 (32-bit)'; F = @('SysWOW64\msvcr120.dll'); Ids = @('Microsoft.VCRedist.2013.x86') },
        @{ N = 'Visual C++ 2012 (64-bit)'; F = @('System32\msvcr110.dll'); Ids = @('Microsoft.VCRedist.2012.x64') },
        @{ N = 'Visual C++ 2012 (32-bit)'; F = @('SysWOW64\msvcr110.dll'); Ids = @('Microsoft.VCRedist.2012.x86') },
        @{ N = 'Visual C++ 2010 (64-bit)'; F = @('System32\msvcr100.dll'); Ids = @('Microsoft.VCRedist.2010.x64') },
        @{ N = 'Visual C++ 2010 (32-bit)'; F = @('SysWOW64\msvcr100.dll'); Ids = @('Microsoft.VCRedist.2010.x86') },
        @{ N = 'DirectX legacy runtime (d3dx9, xinput)'; F = @('System32\d3dx9_43.dll', 'SysWOW64\d3dx9_43.dll', 'SysWOW64\xinput1_3.dll'); Ids = @('Microsoft.DirectX') }
    )
    foreach ($c in $checks) {
        $missing = @($c.F | Where-Object { -not (Test-Path (Join-Path $win $_)) })
        if ($missing.Count -gt 0) {
            $sev = 'MED'
            if ($c.N -like 'DirectX*') { $sev = 'INFO' }
            Add-Finding "rt-$($c.N)" $sev "Missing runtime files: $($c.N)" "Missing: $($missing -join ', '). Programs and games that need them will fail to start or crash." 'InstallRuntime' $c.Ids 'from Microsoft through winget'
        }
    }
}

function Get-EventRules {
    @(
        @{ Key = 'dcom'; P = '^Microsoft-Windows-DistributedCOM$'; Ignore = $true },
        @{ Key = 'tls'; P = '^(Schannel|Microsoft-Windows-CAPI2|Microsoft-Windows-CertificateServicesClient.*)$'; Ignore = $true },
        @{ Key = 'disk'; P = '^(disk|Ntfs|Microsoft-Windows-Ntfs|volmgr|storahci|stornvme|iaStorA|iaStorV|atapi|partmgr|Microsoft-Windows-DiskDiagnostic.*)$'; Sev = 'HIGH'; Title = 'Disk or file-system errors'; Advice = 'Bad sectors, a loose cable or a failing drive can cause these. Run a disk check and keep backups.'; Fix = 'Chkdsk' },
        @{ Key = 'wu'; P = '^Microsoft-Windows-WindowsUpdateClient$'; Sev = 'MED'; Title = 'Windows Update keeps failing'; Advice = 'Resetting the update cache usually fixes it.'; Fix = 'ResetWU' },
        @{ Key = 'kpower'; P = '^Microsoft-Windows-Kernel-Power$'; I = @(41); Sev = 'MED'; Title = 'The PC shut down without a clean shutdown'; Advice = 'Check the charger and battery, overheating and dust. If it repeats, test the memory and power supply.' },
        @{ Key = 'whea'; P = '^Microsoft-Windows-WHEA-Logger$'; Sev = 'HIGH'; Title = 'Hardware errors reported by the CPU or board'; Advice = 'Often overheating or failing hardware. Clean the fans, reapply thermal paste, check temperatures.' },
        @{ Key = 'gpu'; P = '^(Display|nvlddmkm)$'; Sev = 'MED'; Title = 'Graphics driver stopped responding'; Advice = 'Update or reinstall the graphics driver (for an old NVIDIA GeForce, the legacy driver from nvidia.com or the PC maker).' },
        @{ Key = 'net'; P = '^(Microsoft-Windows-WLAN-AutoConfig|Microsoft-Windows-NDIS|Netwtw.*|bcmwl.*|BTHUSB|BTHPORT|BthA2dp|Microsoft-Windows-Bluetooth.*)$'; Sev = 'MED'; Title = 'Wi-Fi or Bluetooth driver errors'; Advice = 'Matches the hangs you described. The Wi-Fi/Bluetooth fixes disable power saving and reset the adapters.'; Fix = 'NetFix' },
        @{ Key = 'dns'; P = '^Microsoft-Windows-DNS-Client$'; I = @(1012, 1014, 1023); Sev = 'INFO'; Title = 'DNS client errors (hosts file or name-resolution policy)'; Advice = 'VPN tools such as Cloudflare WARP or Tailscale often cause these. Make sure C:\Windows\System32\drivers\etc\hosts is readable. Flushing the DNS cache can clear them.'; Fix = 'FlushDns' },
        @{ Key = 'time'; P = '^Microsoft-Windows-Time-Service$'; Sev = 'INFO'; Title = 'Clock synchronization problems'; Advice = 'A wrong clock breaks websites and updates.'; Fix = 'ResyncTime' },
        @{ Key = 'vss'; P = '^volsnap$'; Sev = 'INFO'; Title = 'Shadow copy (restore point) storage problems'; Advice = 'Restore points may fail. Free disk space or reduce System Protection storage.' },
        @{ Key = 'dotnet'; P = '^\.NET Runtime$'; Sev = 'INFO'; Title = '.NET programs crashed'; Advice = 'Update or reinstall the program that crashed (see the log for its name).' },
        @{ Key = 'scm'; P = '^Service Control Manager$'; I = @(7000, 7001, 7009, 7011, 7023, 7024, 7031, 7032, 7034); Special = 'service' },
        @{ Key = 'crash'; P = '^Application Error$'; I = @(1000); Special = 'crash' },
        @{ Key = 'hang'; P = '^Application Hang$'; I = @(1002); Special = 'crash' }
    )
}

function Scan-Events {
    $since = (Get-Date).AddDays(-7)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = @('System', 'Application'); Level = @(1, 2); StartTime = $since } -MaxEvents 2500 -ErrorAction SilentlyContinue)
    if ($ev.Count -eq 0) { return }
    $acks = Get-Acks
    $rules = Get-EventRules
    $buckets = @{}
    $unknown = @()
    foreach ($g in ($ev | Group-Object { '{0}|{1}' -f $_.ProviderName, $_.Id })) {
        $first = $g.Group[0]
        $prov = [string]$first.ProviderName
        $id = [int]$first.Id
        $rule = $null
        foreach ($r in $rules) { if ($prov -match $r.P -and (-not $r.I -or $r.I -contains $id)) { $rule = $r; break } }
        if ($rule -and $rule.Ignore) { continue }
        $key = "evt:$prov|$id"
        if ($rule) { $key = 'rule:' + $rule.Key }
        $cut = [datetime]::MinValue
        if ($acks.ContainsKey($key)) { $cut = $acks[$key] }
        $evs = @($g.Group | Where-Object { $_.TimeCreated -gt $cut })
        if ($evs.Count -eq 0) { continue }
        if ($rule) {
            if (-not $buckets.ContainsKey($key)) { $buckets[$key] = @{ Rule = $rule; Events = @() } }
            $buckets[$key].Events += $evs
        } elseif ($evs.Count -ge 3) {
            $unknown += [pscustomobject]@{ Key = $key; Prov = $prov; Id = $id; Count = $evs.Count; Latest = $evs[0] }
        }
    }
    foreach ($key in $buckets.Keys) {
        $rule = $buckets[$key].Rule
        $evs = @($buckets[$key].Events | Sort-Object TimeCreated -Descending)
        if ($rule.Special -eq 'crash') {
            $apps = @{}
            foreach ($e in $evs) {
                $m = [string]$e.Message
                $app = 'unknown program'
                $mod = ''
                # Event fields first (same on every Windows language), message text only as a fallback.
                $p0 = Get-EvProp $e 0
                if ($p0) { $app = [string]$p0 }
                if ($rule.Key -eq 'crash') { $p3 = Get-EvProp $e 3; if ($p3) { $mod = [string]$p3 } }
                if ($app -eq 'unknown program') {
                    if ($m -match 'Faulting application name:\s*([^,\r\n]+)') { $app = $Matches[1].Trim() } elseif ($m -match 'The program (.+?) version') { $app = $Matches[1].Trim() }
                }
                if (-not $mod -and $m -match 'Faulting module name:\s*([^,\r\n]+)') { $mod = $Matches[1].Trim() }
                $k = "$app|$mod"
                if (-not $apps.ContainsKey($k)) { $apps[$k] = @{ App = $app; Mod = $mod; Count = 0 } }
                $apps[$k].Count++
            }
            foreach ($a in $apps.Values) {
                $rt = $null
                if ($a.Mod) { $rt = Get-RuntimeForModule $a.Mod }
                if ($rt) {
                    Add-Finding "crash-$($a.App)-$($a.Mod)" 'HIGH' "$($a.App) crashed $($a.Count)x because $($a.Mod) is missing or broken" "$($rt.Name) provides this file. Reinstalling it usually fixes the crash." 'InstallRuntime' $rt.Ids 'from Microsoft through winget' $key
                } elseif ($a.Count -ge 3) {
                    $why = ''
                    if ($a.Mod) { $why = " (faulting module: $($a.Mod))" }
                    Add-Finding "crash-$($a.App)-$($a.Mod)" 'INFO' "$($a.App) crashed or hung $($a.Count) times$why" 'Update or reinstall that program. If it is a Windows component, run the system repair.' '' $null '' $key
                }
            }
        } elseif ($rule.Special -eq 'service') {
            $names = @{}
            foreach ($e in $evs) {
                $sn0 = [string](Get-EvProp $e 0)
                if (-not $sn0 -and [string]$e.Message -match 'The (.+?) service') { $sn0 = $Matches[1] }
                if ($sn0) { $names[$sn0] = 1 + [int]$names[$sn0] }
            }
            foreach ($sn in $names.Keys) {
                $dn = $sn -replace "'", "''"
                $svc = Get-CimInstance Win32_Service -Filter "DisplayName='$dn'" -ErrorAction SilentlyContinue
                if ($svc -and $svc.StartMode -eq 'Auto' -and $svc.State -ne 'Running') {
                    Add-Finding "scm-$sn" 'MED' "Service '$sn' failed $($names[$sn])x and is not running" 'It is set to start automatically. Starting it again often works.' 'ServiceStart' $svc.Name '' $key
                } elseif ($names[$sn] -ge 5) {
                    Add-Finding "scm-$sn" 'INFO' "Service '$sn' failed $($names[$sn]) times (it is running now)" 'If it keeps failing, reinstall or update the program that owns it.' '' $null '' $key
                }
            }
        } else {
            $latest = $evs[0]
            $line = (([string]$latest.Message -split "`r?`n")[0])
            if ($line.Length -gt 130) { $line = $line.Substring(0, 127) + '...' }
            $d = "$($evs.Count) event(s) in 7 days, latest $($latest.TimeCreated.ToString('MM-dd HH:mm')): $line $($rule.Advice)"
            $sev = $rule.Sev
            if (-not $sev) { $sev = 'MED' }
            $fix = ''
            if ($rule.Fix) { $fix = $rule.Fix }
            $title = $rule.Title
            $fixArg = $null
            if ($rule.Key -eq 'disk') {
                $letters = @()
                foreach ($e in ($evs | Select-Object -First 60)) { foreach ($mm in [regex]::Matches([string]$e.Message, 'Volume\s+([A-Za-z]):')) { $letters += $mm.Groups[1].Value.ToUpper() } }
                $letters = @($letters | Sort-Object -Unique)
                if ($letters.Count -gt 0) { $fixArg = $letters; $d += " Affected volume(s): $($letters -join ', ')." }
            }
            if ($rule.Key -eq 'wu' -and @($evs | Where-Object { [string]$_.Message -notmatch '\b9[A-Z0-9]{11}\b|0x80073D02' }).Count -eq 0) {
                # Only Microsoft Store apps failed (usually because the app was open): not a Windows Update problem.
                $sev = 'INFO'; $fix = ''
                $title = 'A Microsoft Store app failed to update'
                $d = "$($evs.Count) event(s): $line The app was probably open. Close it and update it from Microsoft Store > Library."
            }
            Add-Finding "rule-$($rule.Key)" $sev $title $d $fix $fixArg '' $key
        }
    }
    foreach ($u in ($unknown | Sort-Object Count -Descending | Select-Object -First 6)) {
        $line = (([string]$u.Latest.Message -split "`r?`n")[0])
        if ($line.Length -gt 130) { $line = $line.Substring(0, 127) + '...' }
        Add-Finding "evt-$($u.Prov)-$($u.Id)" 'INFO' "Recurring error: $($u.Prov) (ID $($u.Id)) x$($u.Count)" "$line Search the web for the provider and ID if it bothers you; nothing is changed automatically." '' $null '' $u.Key
    }
}

# ---------------------------------------------------------------- fixes
function Install-Runtime([string[]]$Ids) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue) -and -not $script:DryRun) {
        Add-Problem 'Install runtime' 'winget was not found' 'Install "App Installer" from the Microsoft Store.'
        return
    }
    foreach ($id in $Ids) {
        if (-not $script:DryRun -and -not (Ask "  Download and install $id from Microsoft through winget?")) { continue }
        if ($script:DryRun) { Say "  [DRY] winget install $id" DarkYellow; Write-Log "[DRY] install $id"; continue }
        Working-Begin "Installing $id ..."
        $o = @(winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String -Stream | Where-Object { $_.Trim() })
        $code = $LASTEXITCODE
        Working-End
        $hex = '0x{0:X8}' -f [uint32]($code -band 0xFFFFFFFFL)
        if ($code -eq 0 -or $hex -eq '0x8A150061' -or $code -eq 3010) {
            Say "  [OK]  $id ready" Green; Write-Log "runtime ok $id"; $script:OkCount++
            if ($code -eq 3010) { $script:NeedReboot = $true }
        } else {
            Say "  [x]   $id failed, code $hex" Red
            Add-Problem "Install $id" "winget exit code $hex" ("Last output: " + (($o | Select-Object -Last 3) -join ' / '))
        }
    }
}

function Install-WuUpdates([string]$Which) {
    $list = @($script:WuSoftware)
    if ($Which -eq 'Driver') { $list = @($script:WuDrivers) }
    if ($list.Count -eq 0) { Say '  Nothing to install.'; return }
    $mb = [math]::Round((($list | Measure-Object MaxDownloadSize -Sum).Sum) / 1MB)
    foreach ($u in $list) { Say "    - $($u.Title)" White }
    if ($script:DryRun) { Say "  [DRY] download about $mb MB and install $($list.Count) update(s)" DarkYellow; Write-Log "[DRY] WU $Which"; return }
    if (-not (Ask "  Download about $mb MB from Windows Update and install these?")) { return }
    try {
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $list) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }
        $session = New-Object -ComObject Microsoft.Update.Session
        Working-Begin "Downloading $($coll.Count) update(s) ..."
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $coll
        [void]$dl.Download()
        Working-End
        $ready = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $coll.Count; $i++) { if ($coll.Item($i).IsDownloaded) { [void]$ready.Add($coll.Item($i)) } }
        if ($ready.Count -eq 0) { Add-Problem "Windows Update $Which" 'Nothing could be downloaded' 'Check the internet connection, or reset Windows Update from the Doctor.'; return }
        Working-Begin "Installing $($ready.Count) update(s) (this can take a while) ..."
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $ready
        $ires = $inst.Install()
        Working-End
        for ($i = 0; $i -lt $ready.Count; $i++) {
            $r = $ires.GetUpdateResult($i)
            $t = $ready.Item($i).Title
            if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) { Say "  [OK]  $t" Green; Write-Log "WU ok $t"; $script:OkCount++ }
            else { Say "  [x]   $t (result $($r.ResultCode), 0x$('{0:X8}' -f [uint32]$r.HResult))" Red; Add-Problem "Install $t" "Windows Update result $($r.ResultCode)" ('HResult 0x{0:X8}' -f [uint32]$r.HResult) }
        }
        if ($ires.RebootRequired) { $script:NeedReboot = $true; Say '  A restart is required to finish.' Yellow }
    } catch {
        Working-End
        Say "  [x]   Windows Update failed: $($_.Exception.Message)" Red
        Add-ErrorRecord "Install Windows $Which updates" $_
    }
}

function Reset-WindowsUpdate {
    if (-not $script:DryRun -and -not (Ask '  This renames the update cache (SoftwareDistribution, catroot2). Update history is cleared. Continue?')) { return }
    Invoke-Act 'Reset Windows Update components' {
        $svc = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
        foreach ($s in $svc) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        foreach ($p in @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")) {
            if (Test-Path $p) { Rename-Item -Path $p -NewName ((Split-Path $p -Leaf) + ".bak_$stamp") -ErrorAction Stop }
        }
        foreach ($s in $svc) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    }
}

function Invoke-ChkdskFix([string[]]$Drives) {
    Say '[+] Disk check (read-only online scan first)' Cyan
    $targets = @($Drives | Where-Object { $_ } | ForEach-Object { "${_}:" })
    if ($targets.Count -eq 0) { $targets = @($env:SystemDrive) }
    foreach ($dv in $targets) {
        if ($script:DryRun) { Say "  [DRY] chkdsk $dv /scan, then offer /f if errors are found" DarkYellow; Write-Log "[DRY] chkdsk $dv"; continue }
        Working-Begin "Scanning $dv (read-only, can take minutes) ..."
        $o = chkdsk.exe $dv /scan
        $code = $LASTEXITCODE
        Working-End
        Write-Log ("chkdsk $dv exit $code : " + (($o | Select-Object -Last 5) -join ' | '))
        if ($code -le 1) { Say "  [OK]  $dv has no errors" Green; $script:OkCount++; continue }
        Say "  [!!]  $dv has file-system errors (code $code). Back up important files first." Yellow
        if (Ask "  Repair $dv now with chkdsk /f? It may need a restart") {
            Invoke-Act "chkdsk $dv /f" { 'Y' | chkdsk.exe $dv /f | Out-Null }
            $script:NeedReboot = $true
        }
    }
}

function Invoke-Fix($F) {
    Say ("  -> {0}" -f $F.Title) White
    switch ($F.Fix) {
        'Restart' {
            if ($script:DryRun) { Say '  [DRY] restart Windows' DarkYellow }
            elseif (Ask '  Restart Windows now? Save your work first') { Write-Log 'Restart requested by Doctor'; Restart-Computer -Force }
        }
        'Clean'        { Invoke-Clean }
        'InstallWU'    { Install-WuUpdates ([string]$F.FixArg) }
        'InstallRuntime' { Install-Runtime @($F.FixArg) }
        'ScanDevices'  { Invoke-Act 'Rescan hardware (pnputil /scan-devices)' { pnputil.exe /scan-devices | Out-Null; if ($LASTEXITCODE -ne 0) { throw "pnputil exit code $LASTEXITCODE" } } }
        'ResetWU'      { Reset-WindowsUpdate }
        'Chkdsk'       { Invoke-ChkdskFix @($F.FixArg) }
        'FlushDns'     { Invoke-Act 'Flush the DNS cache' { Clear-DnsClientCache } }
        'FirewallOn'   { $fwn = @($F.FixArg); Invoke-Act 'Turn Windows Firewall on' { Add-Journal @{ Type = 'firewall'; Profiles = $fwn }; Set-NetFirewallProfile -Profile $fwn -Enabled True -ErrorAction Stop } }
        'UacOn' {
            if ($script:DryRun -or (Ask '  Turn User Account Control on? A restart is needed, and admin-level programs will then ask for confirmation')) {
                Set-RegJournaled 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 1 'Turn User Account Control on (restart needed)'
                $script:NeedReboot = $true
            }
        }
        'RdpOff'       { Set-RegJournaled 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1 'Turn Remote Desktop off' }
        'Smb1Off'      { Invoke-Act 'Turn SMBv1 off (restart needed)' { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null; Add-Journal @{ Type = 'optfeature'; Name = 'SMB1Protocol' } }; $script:NeedReboot = $true }
        'GuestOff'     { Invoke-Act 'Disable the Guest account' { Disable-LocalUser -Name Guest -ErrorAction Stop; Add-Journal @{ Type = 'localuser'; Name = 'Guest' } } }
        'ResyncTime'   { Invoke-Act 'Resync the clock' { Start-Service -Name w32time -ErrorAction SilentlyContinue; w32tm.exe /resync | Out-Null; if ($LASTEXITCODE -ne 0) { throw "w32tm exit code $LASTEXITCODE" } } }
        'ServiceStart' { $sn = [string]$F.FixArg; Invoke-Act "Start service $sn" { Start-Service -Name $sn -ErrorAction Stop } }
        'NetFix'       { Invoke-PowerSavingFix; Invoke-WifiReset; Invoke-BluetoothReset }
        'DefenderSigs' { Invoke-Act 'Update Defender definitions' { Update-MpSignature -ErrorAction Stop } }
        'Repair'       { Invoke-Repair }
        'TrimOn'       { Invoke-TrimOn }
        'PrepareAhci'  { Invoke-PrepareAhci }
        'ConvertGpt'   { Invoke-ConvertGpt }
    }
}

# ---------------------------------------------------------------- doctor main
function Show-Findings {
    $order = @{ HIGH = 0; MED = 1; INFO = 2 }
    $items = @($script:Findings | Sort-Object { $order[$_.Sev] })
    $script:Findings.Clear()
    foreach ($i in $items) { [void]$script:Findings.Add($i) }
    $labels = @{
        Restart = 'restart Windows'; Clean = 'clean files'; InstallWU = 'install through Windows Update'; InstallRuntime = 'download and install from Microsoft'
        ScanDevices = 'rescan hardware'; ResetWU = 'reset Windows Update components'; Chkdsk = 'check the disk'; ResyncTime = 'resync the clock'
        ServiceStart = 'start the service'; NetFix = 'Wi-Fi/Bluetooth fixes'; DefenderSigs = 'update definitions'; Repair = 'SFC + DISM repair'; FlushDns = 'flush the DNS cache'; TrimOn = 'turn TRIM on'; PrepareAhci = 'prepare Windows for AHCI'; ConvertGpt = 'convert to GPT (guided)'
        FirewallOn = 'turn the firewall on'; UacOn = 'turn UAC on (restart needed)'; RdpOff = 'turn Remote Desktop off'; Smb1Off = 'turn SMBv1 off (restart needed)'; GuestOff = 'disable the Guest account'
    }
    Write-Host ''
    if ($script:Findings.Count -eq 0) { Say '  No problems found. This PC looks healthy.' Green; return }
    $n = 0
    foreach ($f in $script:Findings) {
        $n++
        $c = 'Gray'
        if ($f.Sev -eq 'HIGH') { $c = 'Red' } elseif ($f.Sev -eq 'MED') { $c = 'Yellow' }
        Say ('  {0,2}. [{1}] {2}' -f $n, $f.Sev, $f.Title) $c
        Write-Wrapped $f.Detail 8 78 DarkGray
        if ($f.Fix) {
            $lab = $labels[$f.Fix]
            $dl = ''
            if ($f.Download) { $dl = "  (download: $($f.Download))" }
            Say ("        Fix: {0}{1}" -f $lab, $dl) Cyan
        }
    }
}
function Save-Health {
    $h = @($script:Findings | Where-Object { $_.Sev -eq 'HIGH' }).Count
    $m = @($script:Findings | Where-Object { $_.Sev -eq 'MED' }).Count
    $i = @($script:Findings | Where-Object { $_.Sev -eq 'INFO' }).Count
    try {
        @{ Time = (Get-Date).ToString('o'); High = $h; Med = $m; Info = $i } | ConvertTo-Json | Set-Content -Path $script:HealthFile -Encoding UTF8
        $lines = @("Turbo Optimizer health report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "HIGH $h   MED $m   INFO $i", '')
        foreach ($f in $script:Findings) { $lines += "[$($f.Sev)] $($f.Title)"; $lines += "    $($f.Detail)"; if ($f.Fix) { $lines += "    Fix available: $($f.Fix)" } }
        $lines | Set-Content -Path $script:HealthReport -Encoding UTF8
    } catch {}
    Write-Log "Doctor: HIGH=$h MED=$m INFO=$i"
}
function Register-HealthTask {
    $name = 'TurboOptimizer Health Check'
    Invoke-Act 'Schedule a daily background health check (scan only, changes nothing)' {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Doctor -ScanOnly' -f $PSCommandPath)
        $logon = New-ScheduledTaskTrigger -AtLogOn
        $logon.Delay = 'PT10M'
        $trg = @((New-ScheduledTaskTrigger -Daily -At 1pm), $logon)
        $prin = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
        Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
    }
}
function Unregister-HealthTask {
    Invoke-Act 'Remove the background health check' { Unregister-ScheduledTask -TaskName 'TurboOptimizer Health Check' -Confirm:$false -ErrorAction Stop }
}

function Invoke-Doctor([switch]$ScanOnly, [string[]]$Only, [string]$Title = 'Doctor') {
    Say "[+] $Title - scanning this PC (read-only)" Cyan
    $script:Findings.Clear()
    $script:NeedReboot = $false
    $scans = @(
        @('Windows and security', 'Scan-System'), @('Windows Update', 'Scan-Updates'), @('devices and drivers', 'Scan-Devices'),
        @('runtime libraries', 'Scan-Runtimes'), @('drives', 'Scan-DiskHealth'), @('network exposure and accounts', 'Scan-Security'),
        @('disk and boot setup', 'Scan-Boot'),
        @('the event log (7 days)', 'Scan-Events')
    )
    if ($Only -and $Only.Count -gt 0) { $scans = @($scans | Where-Object { $Only -contains $_[1] }) }
    foreach ($s in $scans) {
        Working-Begin "Checking $($s[0]) ..."
        try { & $s[1] } catch { Working-End; Add-ErrorRecord "Doctor scan: $($s[0])" $_ }
        Working-End
    }
    Show-Findings
    if (-not $Only) { Save-Health }
    if ($ScanOnly) { return }
    $fixable = @($script:Findings | Where-Object { $_.Fix })
    Write-Host ''
    if ($fixable.Count -eq 0) { Say '  Nothing here can be fixed automatically. The advice above is what to do next.' Gray }
    $ans = 'A'
    if (-not $script:AutoYes) {
        $ans = (Read-Host '  Fix: A = all fixable, numbers (1,3), I + numbers = ignore, S = schedule daily check, U = unschedule, Enter = skip').Trim().ToUpper()
    }
    if ($ans -eq 'S') { Register-HealthTask; return }
    if ($ans -eq 'U') { Unregister-HealthTask; return }
    if (-not $ans) { return }
    $chosen = @()
    if ($ans -eq 'A') { $chosen = $fixable }
    else {
        $ignore = $ans.StartsWith('I')
        $nums = $ans.TrimStart('I')
        foreach ($tok in ($nums -split ',')) {
            $k = 0
            if (-not [int]::TryParse($tok.Trim(), [ref]$k) -or $k -lt 1 -or $k -gt $script:Findings.Count) { continue }
            $f = $script:Findings[$k - 1]
            if ($ignore) { if ($f.AckKey) { Set-Ack $f.AckKey; Say "  Ignored: $($f.Title)" DarkGray } else { Say "  Cannot ignore: $($f.Title)" Yellow } }
            elseif ($f.Fix) { $chosen += $f }
            else { Say "  No automatic fix for: $($f.Title)" Yellow }
        }
    }
    Invoke-DoctorFixSelected @($chosen | ForEach-Object { $_.Id })
    if (-not $script:AutoYes -and $chosen.Count -gt 0 -and (Ask '  Scan again to confirm?')) { Invoke-Doctor -ScanOnly -Only $Only -Title $Title }
}
# Runs the fixes for the chosen findings of the last scan (used by the menu and by the graphical version).
function Invoke-DoctorFixSelected([string[]]$Ids, [string]$Mode = 'Fix') {
    $chosen = @($script:Findings | Where-Object { $Ids -contains $_.Id })
    if ($Mode -eq 'Ignore') {
        foreach ($f in $chosen) { if ($f.AckKey) { Set-Ack $f.AckKey; Say "  Ignored: $($f.Title)" DarkGray } else { Say "  Cannot ignore: $($f.Title)" Yellow } }
        return
    }
    $done = @{}
    foreach ($f in $chosen) {
        if (-not $f.Fix) { Say "  No automatic fix for: $($f.Title)" Yellow; continue }
        $sig = "$($f.Fix)|$((@($f.FixArg)) -join ',')"
        if ($done.ContainsKey($sig)) { continue }
        $done[$sig] = $true
        $before = $script:Problems.Count
        Invoke-Fix $f
        if ($script:Problems.Count -eq $before -and $f.AckKey) { Set-Ack $f.AckKey }
    }
    if ($script:NeedReboot) { Say '  A restart is recommended to finish these fixes.' Yellow }
}

# ================================================================ PLATFORM (works across vendors and Windows versions)
function Get-Platform {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $chassis = @()
    try { $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes) } catch {}
    $bat = @()
    try { $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop) } catch {}
    $laptop = ($bat.Count -gt 0) -or (@($chassis | Where-Object { @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) -contains [int]$_ }).Count -gt 0)
    $vm = ("$($cs.Model) $($cs.Manufacturer)" -match 'Virtual|VMware|VirtualBox|KVM|QEMU|Xen|Hyper-V')
    $notes = @()
    $build = [int]$os.BuildNumber
    if ($build -lt 17763) { $notes += 'Windows older than 10 version 1809 is not supported' }
    if ((Get-UICulture).Name -notlike 'en*') { $notes += "Windows language is $((Get-UICulture).Name): checks that read Windows text are limited, everything else works" }
    if ($vm) { $notes += 'Virtual machine: hardware fixes (Wi-Fi, Bluetooth, drivers, disk health) do not apply' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $notes += 'ARM64 PC: not tested' }
    [pscustomobject]@{
        Vendor = ("$($cs.Manufacturer)").Trim(); Model = ("$($cs.Model)").Trim(); Build = $build; Caption = $os.Caption
        IsWin11 = ($build -ge 22000); Laptop = $laptop; HasBattery = ($bat.Count -gt 0); VM = $vm; Notes = $notes
    }
}
function Get-VendorSite {
    $v = ''
    if ($script:Plat) { $v = $script:Plat.Vendor }
    if ($v -match 'Dell') { return 'dell.com/support' }
    if ($v -match 'HP|Hewlett') { return 'support.hp.com' }
    if ($v -match 'LENOVO') { return 'support.lenovo.com' }
    if ($v -match 'ASUS') { return 'asus.com/support' }
    if ($v -match 'Acer') { return 'acer.com/support' }
    if ($v -match 'Micro-Star|MSI') { return 'msi.com/support' }
    if ($v -match 'SAMSUNG') { return 'samsung.com/support' }
    if ($v -match 'Toshiba|Dynabook') { return 'support.dynabook.com' }
    if ($v -match 'Microsoft') { return 'support.microsoft.com' }
    return "the maker's support site"
}
function Get-EvProp($Ev, [int]$Index) {
    try { if ($Ev.Properties.Count -gt $Index) { return $Ev.Properties[$Index].Value } } catch {}
    return $null
}

# ================================================================ MICROSOFT DEFENDER (turn off reversibly, turn on, repair, update)
$script:DefPolicyRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$script:DefPolicies = @(
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; N = 'DisableAntiSpyware' },
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; N = 'DisableRealtimeMonitoring' },
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; N = 'DisableBehaviorMonitoring' },
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; N = 'DisableOnAccessProtection' },
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; N = 'DisableIOAVProtection' },
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection'; N = 'DisableScanOnRealtimeEnable' }
)
function Get-AvProducts {
    try { return @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { [string]$_.displayName }) } catch { return @() }
}
function Show-DefenderStatus {
    Say '[+] Microsoft Defender status' Cyan
    $av = @(Get-AvProducts)
    if ($av.Count -gt 0) { Say ('  Antivirus products registered: ' + ($av -join ', ')) } else { Say '  Antivirus products registered: unknown' DarkGray }
    $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    if ($svc) { Say "  Defender service: $($svc.Status), start type $($svc.StartType)" } else { Say '  Defender service: NOT FOUND (components are missing or damaged)' Red }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Say "  Real-time protection: $($mp.RealTimeProtectionEnabled)   Tamper Protection: $($mp.IsTamperProtected)   Mode: $($mp.AMRunningMode)"
        Say ('  Definitions: {0}  ({1:N0} days old)   Engine {2}   Platform {3}' -f $mp.AntivirusSignatureVersion, ((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays, $mp.AMEngineVersion, $mp.AMProductVersion)
    } catch { Say "  Could not read Defender state: $($_.Exception.Message)" Yellow }
    $pol = @()
    foreach ($d in $script:DefPolicies) {
        if (Test-Path $d.P) { $v = (Get-ItemProperty -Path $d.P -Name $d.N -ErrorAction SilentlyContinue).($d.N); if ($null -ne $v) { $pol += "$($d.N)=$v" } }
    }
    if ($pol.Count -gt 0) { Say ('  Policies set: ' + ($pol -join ', ')) Yellow } else { Say '  Policies set: none' DarkGray }
}
function Invoke-DefenderDisable {
    Say '[+] Turn Microsoft Defender off (reversible)' Cyan
    Write-Wrapped 'Windows has no supported way to uninstall Defender, and hacks that delete its files break Windows Update and are undone by updates. This option TURNS IT OFF in a way you can fully reverse (option C or menu 12). It does not delete anything.' 2 78 Gray
    $others = @(Get-AvProducts | Where-Object { $_ -and $_ -notmatch 'Windows Defender|Microsoft Defender' })
    if ($others.Count -eq 0) {
        Write-Host ''
        Say '  WARNING: no other antivirus is installed. With Defender off this PC has NO malware protection.' Red
        Write-Wrapped 'Install another antivirus first (Windows then turns Defender off by itself), or only use this PC offline or for trusted work.' 2 78 Yellow
    } else { Say ('  Another antivirus is registered: ' + ($others -join ', ') + '. Windows normally turns Defender off by itself when one is installed.') DarkGray }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.IsTamperProtected) {
            Write-Host ''
            Say '  Tamper Protection is ON, so Windows blocks any program from turning Defender off.' Yellow
            Write-Wrapped 'Turn it off yourself: Windows Security > Virus & threat protection > Manage settings > Tamper Protection = Off. This tool cannot and will not bypass it. Then run this option again.' 2 78 Gray
            if (-not $script:AutoYes -and -not $script:DryRun) { Start-Process 'windowsdefender://threatsettings' }
            return
        }
    } catch {}
    if (-not $script:DryRun -and -not $script:AutoYes) {
        $t = Read-Host '  Type DISABLE (capital letters) to continue, anything else cancels'
        if ($t -cne 'DISABLE') { Say '  Cancelled.' DarkGray; return }
        if (Ask '  Create a restore point first?') { Invoke-RestorePoint }
    }
    foreach ($d in $script:DefPolicies) {
        $existed = $false
        $prev = 0
        if (Test-Path $d.P) { $cur = (Get-ItemProperty -Path $d.P -Name $d.N -ErrorAction SilentlyContinue).($d.N); if ($null -ne $cur) { $existed = $true; $prev = [int]$cur } }
        Invoke-Act "Policy $($d.N) = 1" {
            Add-Journal @{ Type = 'defender-policy'; Path = $d.P; Name = $d.N; Existed = $existed; Previous = $prev }
            if (-not (Test-Path $d.P)) { New-Item -Path $d.P -Force | Out-Null }
            Set-ItemProperty -Path $d.P -Name $d.N -Value 1 -Type DWord -ErrorAction Stop
        }
    }
    Invoke-Act 'Turn off real-time, behavior and script scanning; stop sample upload' {
        $mp = Get-MpPreference -ErrorAction Stop
        $prev = @{ DisableRealtimeMonitoring = [bool]$mp.DisableRealtimeMonitoring; DisableBehaviorMonitoring = [bool]$mp.DisableBehaviorMonitoring
                   DisableIOAVProtection = [bool]$mp.DisableIOAVProtection; DisableScriptScanning = [bool]$mp.DisableScriptScanning
                   MAPSReporting = [int]$mp.MAPSReporting; SubmitSamplesConsent = [int]$mp.SubmitSamplesConsent }
        Add-Journal @{ Type = 'defender-prefs'; Prev = $prev }
        Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true -DisableIOAVProtection $true -DisableScriptScanning $true -MAPSReporting 0 -SubmitSamplesConsent 2 -ErrorAction Stop
    }
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' }) } catch {}
    foreach ($tk in $tasks) {
        Invoke-Act "Disable scheduled task $($tk.TaskName)" {
            Add-Journal @{ Type = 'defender-task'; Path = $tk.TaskPath; Name = $tk.TaskName }
            Disable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName -ErrorAction Stop | Out-Null
        }
    }
    if ($script:DryRun) { return }
    Start-Sleep -Seconds 2
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.RealTimeProtectionEnabled) {
            Say '  Windows kept real-time protection on (Defender protects itself on this build).' Yellow
            Write-Wrapped 'Turn off "Real-time protection" in Windows Security by hand, then check with option A. Nothing else here can force it off.' 2 78 Gray
        } else { Say '  Defender is now OFF. Turn it back on any time with option C.' Green }
    } catch {}
}
function Undo-DefenderEntry($E) {
    switch ($E.Type) {
        'defender-policy' {
            if ($E.Existed) { Set-ItemProperty -Path $E.Path -Name $E.Name -Value ([int]$E.Previous) -Type DWord -ErrorAction Stop }
            elseif (Test-Path $E.Path) { Remove-ItemProperty -Path $E.Path -Name $E.Name -ErrorAction SilentlyContinue }
        }
        'defender-prefs' {
            $p = @{}
            foreach ($n in 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableIOAVProtection', 'DisableScriptScanning') { if ($null -ne $E.Prev.$n) { $p[$n] = [bool]$E.Prev.$n } }
            if ($null -ne $E.Prev.MAPSReporting) { $p['MAPSReporting'] = [int]$E.Prev.MAPSReporting }
            if ($null -ne $E.Prev.SubmitSamplesConsent) { $p['SubmitSamplesConsent'] = [int]$E.Prev.SubmitSamplesConsent }
            Set-MpPreference @p -ErrorAction Stop
        }
        'defender-task' { Enable-ScheduledTask -TaskPath $E.Path -TaskName $E.Name -ErrorAction Stop | Out-Null }
    }
}
function Invoke-DefenderUpdate {
    Say '[+] Update Defender definitions' Cyan
    if ($script:DryRun) { Say '  [DRY] Update-MpSignature, then the signed Microsoft package if that fails' DarkYellow; Write-Log '[DRY] Defender update'; return }
    Working-Begin 'Asking Windows Update for new definitions ...'
    $ok = $true
    try { Update-MpSignature -ErrorAction Stop } catch { $ok = $false; $msg = $_.Exception.Message }
    Working-End
    if ($ok) { Say '  [OK]  Definitions updated' Green; Write-Log 'Defender definitions updated'; $script:OkCount++; return }
    Say "  Windows Update route failed: $msg" Yellow
    $arch = 'x64'
    if (-not [Environment]::Is64BitOperatingSystem) { $arch = 'x86' } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    if (-not (Ask "  Download the offline definition package (mpam-fe.exe, about 200 MB) from Microsoft?")) { return }
    $dest = Join-Path $env:TEMP 'mpam-fe.exe'
    try {
        Working-Begin 'Downloading from go.microsoft.com ...'
        Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?LinkID=121721&arch=$arch" -OutFile $dest -UseBasicParsing -ErrorAction Stop
        Working-End
        $sig = Get-AuthenticodeSignature -FilePath $dest
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            Add-Problem 'Defender offline update' 'The downloaded file is not signed by Microsoft, so it was deleted' "Signature status: $($sig.Status)"
            return
        }
        Working-Begin 'Installing definitions ...'
        $pr = Start-Process -FilePath $dest -Wait -PassThru
        Working-End
        if ($pr.ExitCode -eq 0) { Say '  [OK]  Definitions installed from the Microsoft package' Green; $script:OkCount++ }
        else { Add-Problem 'Defender offline update' "Installer exit code $($pr.ExitCode)" 'Make sure Defender is turned on (option C), then retry.' }
    } catch {
        Working-End
        Add-ErrorRecord 'Defender offline update' $_
    } finally { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
}
function Invoke-DefenderEnable {
    Say '[+] Turn Microsoft Defender on, repair if needed, update' Cyan
    $entries = @(Get-Journal | Where-Object { $_.Type -like 'defender-*' })
    if ($entries.Count -gt 0) {
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $e = $entries[$i]
            Invoke-Act "Restore $($e.Type) $($e.Name)" { Undo-DefenderEntry $e }
        }
        if (-not $script:DryRun) { Save-Journal @(Get-Journal | Where-Object { $_.Type -notlike 'defender-*' }) }
    } else {
        foreach ($d in $script:DefPolicies) {
            if (Test-Path $d.P) { Invoke-Act "Remove policy $($d.N)" { Remove-ItemProperty -Path $d.P -Name $d.N -ErrorAction SilentlyContinue } }
        }
        Invoke-Act 'Turn real-time protection on' { Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -DisableScriptScanning $false -ErrorAction Stop }
        try { foreach ($tk in @(Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' -ErrorAction Stop | Where-Object { $_.State -eq 'Disabled' })) { Invoke-Act "Enable scheduled task $($tk.TaskName)" { Enable-ScheduledTask -TaskPath $tk.TaskPath -TaskName $tk.TaskName | Out-Null } } } catch {}
    }
    foreach ($sn in 'WinDefend', 'WdNisSvc') {
        $s = Get-Service -Name $sn -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running') { Invoke-Act "Start service $sn" { Start-Service -Name $sn -ErrorAction Stop } }
    }
    if (-not $script:DryRun -and -not (Get-Service -Name WinDefend -ErrorAction SilentlyContinue)) {
        Say '  The Defender service is missing: Windows files are damaged.' Red
        if (Ask '  Run the system repair (DISM + SFC) and reset the Windows Security app?') {
            Invoke-Repair
            Invoke-Act 'Reset the Windows Security app' { Get-AppxPackage -AllUsers Microsoft.SecHealthUI | Reset-AppxPackage -ErrorAction Stop }
            Say '  Restart Windows, then check status with option A. If the service is still missing, the supported fix is an in-place repair upgrade of Windows.' Yellow
        }
    }
    Invoke-DefenderUpdate
}
function Invoke-DefenderMenu {
    if ($script:AutoYes) { Show-DefenderStatus; Invoke-DefenderDisable; Invoke-DefenderEnable; return }
    while ($true) {
        Say ''
        Say '[ MICROSOFT DEFENDER ]' Cyan
        Say '  A. Status'
        Say '  B. Turn off (reversible, nothing is deleted)'
        Say '  C. Turn on + repair + update'
        Say '  D. Update definitions only'
        Say '  E. Why it cannot be removed completely'
        Say '  0. Back'
        switch ((Read-Host '>> Select').Trim().ToUpper()) {
            'A' { Show-DefenderStatus }
            'B' { Invoke-DefenderDisable }
            'C' { Invoke-DefenderEnable }
            'D' { Invoke-DefenderUpdate }
            'E' {
                Write-Wrapped 'Defender is part of Windows itself (services, drivers and the Security app). Microsoft offers no uninstall on Windows 10/11; Uninstall-WindowsFeature works only on Windows Server. Deleting its files by force breaks Windows Update and servicing, and updates put it back. Tamper Protection also blocks changes on purpose. So this tool turns it off cleanly and can turn it on again, which gives the same result without damaging Windows.' 2 78 Gray
            }
            '0' { return }
        }
    }
}

# ================================================================ EXTRA UNDO TYPES
function Describe-ExtraEntry($E) {
    switch ($E.Type) {
        'firewall'        { return "turn Windows Firewall off again for $(@($E.Profiles) -join ', ')" }
        'regvalue'        { return "restore registry value $($E.Name)" }
        'optfeature'      { return "re-enable Windows feature $($E.Name)" }
        'localuser'       { return "re-enable account $($E.Name)" }
        'dns'             { return "restore DNS settings of adapter $($E.Index)" }
        'hibernate'       { return 'turn hibernation back on' }
        'trim'            { return 'put the TRIM setting back as it was' }
        'bios'            { return "put the BIOS option $($E.Name) back to $($E.Previous)" }
        'compactos'       { return 'undo Windows file compression (CompactOS)' }
        'startup-delayed' { return "start $($E.Name) at sign-in again (remove its delayed task)" }
        default           { return "$($E.Type)" }
    }
}
function Undo-ExtraEntry($E) {
    switch ($E.Type) {
        'firewall'   { Set-NetFirewallProfile -Profile @($E.Profiles) -Enabled False -ErrorAction Stop }
        'regvalue'   {
            if ($E.Existed) { Set-ItemProperty -Path $E.Path -Name $E.Name -Value ([int]$E.Previous) -Type DWord -ErrorAction Stop }
            else { Remove-ItemProperty -Path $E.Path -Name $E.Name -ErrorAction SilentlyContinue }
        }
        'optfeature' { Enable-WindowsOptionalFeature -Online -FeatureName $E.Name -NoRestart -ErrorAction Stop | Out-Null }
        'localuser'  { Enable-LocalUser -Name $E.Name -ErrorAction Stop }
        'dns' {
            if ($E.Auto) { Set-DnsClientServerAddress -InterfaceIndex ([int]$E.Index) -ResetServerAddresses -ErrorAction Stop }
            else { Set-DnsClientServerAddress -InterfaceIndex ([int]$E.Index) -ServerAddresses @($E.Previous) -ErrorAction Stop }
        }
        'hibernate'  { powercfg /hibernate on; if ($LASTEXITCODE -ne 0) { throw 'powercfg /hibernate on failed' } }
        'trim'       { fsutil behavior set DisableDeleteNotify ([int]$E.Previous) | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'fsutil failed' } }
        'bios'       { Set-BiosOption ([string]$E.Vendor) ([string]$E.Name) ([string]$E.Previous) }
        'compactos'  { compact.exe /compactOS:never | Out-Null }
        'startup-delayed' {
            Unregister-ScheduledTask -TaskName $E.Task -Confirm:$false -ErrorAction SilentlyContinue
            if ($E.Kind -eq 'RunKey') { Set-ItemProperty -Path $E.Location -Name $E.Name -Value $E.Value -ErrorAction Stop }
            else { Move-Item -LiteralPath $E.Backup -Destination $E.Original -ErrorAction Stop }
        }
        default { throw "No undo rule for entry type '$($E.Type)'" }
    }
}
function Set-RegJournaled([string]$Path, [string]$Name, [int]$Value, [string]$Desc) {
    Invoke-Act $Desc {
        $existed = $false
        $prev = 0
        if (Test-Path $Path) { $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name; if ($null -ne $cur) { $existed = $true; $prev = [int]$cur } }
        Add-Journal @{ Type = 'regvalue'; Path = $Path; Name = $Name; Existed = $existed; Previous = $prev }
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -ErrorAction Stop
    }
}

# ================================================================ FREE UP SPACE
function Get-PathBytes([string]$Path, [int]$TimeoutSec = 40) {
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [int64](Get-Item -LiteralPath $Path -Force).Length }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = [int64]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { break }
        $d = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($d)) { try { $total += (New-Object System.IO.FileInfo $f).Length } catch {} }
            foreach ($s in [System.IO.Directory]::EnumerateDirectories($d)) {
                try { if (-not ([System.IO.File]::GetAttributes($s) -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($s) } } catch {}
            }
        } catch {}
    }
    return $total
}
# Measures many folders at once on a few threads, with an overall time budget. Items: objects with Paths and Limit.
# Returns one size per item, or $null for items that did not finish in time.
function Measure-PathsParallel($Items, [int]$BudgetSec = 40, [int]$Threads = 4) {
    $fn = (Get-Command Get-PathBytes).ScriptBlock.ToString()
    $code = "param(`$paths, `$t)`nfunction Get-PathBytes {`n$fn`n}`n`$s = [int64]0; foreach (`$p in `$paths) { `$s += Get-PathBytes `$p `$t }; `$s"
    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads)
    $pool.Open()
    $jobs = @()
    foreach ($it in $Items) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($code).AddArgument(@($it.Paths)).AddArgument([int]$it.Limit)
        $jobs += [pscustomobject]@{ Ps = $ps; H = $ps.BeginInvoke() }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $BudgetSec) {
        $left = @($jobs | Where-Object { -not $_.H.IsCompleted }).Count
        if ($left -eq 0) { break }
        Working-Begin ('Measuring folders ({0}/{1}) ...' -f ($jobs.Count - $left), $jobs.Count)
        Start-Sleep -Milliseconds 250
    }
    $res = @()
    foreach ($j in $jobs) {
        $val = $null
        if ($j.H.IsCompleted) { try { $val = [int64]@($j.Ps.EndInvoke($j.H))[0] } catch {} } else { try { $j.Ps.Stop() } catch {} }
        $res += $val
        $j.Ps.Dispose()
    }
    $pool.Close(); $pool.Dispose()
    Working-End
    return , $res
}
function Get-SpaceCandidates {
    $l = $env:LOCALAPPDATA; $r = $env:APPDATA; $u = $env:USERPROFILE; $w = $env:SystemRoot; $pd = $env:ProgramData
    @(
        @{ Name = 'npm cache'; Paths = @("$l\npm-cache", "$r\npm-cache"); Safe = $true; Procs = @(); Note = 'downloaded again when needed' },
        @{ Name = 'pip cache'; Paths = @("$l\pip\Cache"); Safe = $true; Procs = @(); Note = 'downloaded again when needed' },
        @{ Name = 'Yarn cache'; Paths = @("$l\Yarn\Cache"); Safe = $true; Procs = @(); Note = 'downloaded again when needed' },
        @{ Name = 'VS Code cache and logs'; Paths = @("$r\Code\Cache", "$r\Code\CachedData", "$r\Code\CachedExtensionVSIXs", "$r\Code\logs", "$r\Code\Code Cache", "$r\Code\GPUCache"); Safe = $true; Procs = @('Code'); Note = 'rebuilt automatically' },
        @{ Name = 'Spotify offline cache'; Paths = @("$l\Spotify\Data", "$l\Spotify\Storage"); Safe = $true; Procs = @('Spotify'); Note = 'songs are fetched again' },
        @{ Name = 'Windows error reports'; Paths = @("$pd\Microsoft\Windows\WER\ReportArchive", "$pd\Microsoft\Windows\WER\ReportQueue"); Safe = $true; Procs = @(); Note = 'old crash reports' },
        @{ Name = 'Crash dumps'; Paths = @("$l\CrashDumps", "$w\Minidump", "$w\MEMORY.DMP"); Safe = $true; Procs = @(); Note = 'only useful to debug crashes' },
        @{ Name = 'Delivery Optimization cache'; Paths = @("$w\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"); Safe = $true; Procs = @(); Note = 'update files shared with other PCs' },
        @{ Name = 'Downloads folder'; Paths = @("$u\Downloads"); Safe = $false; Procs = @(); Note = 'yours: review and delete by hand' },
        @{ Name = 'Docker / WSL data'; Paths = @("$l\Docker\wsl"); Safe = $false; Procs = @(); Note = 'use the Docker prune offer below' },
        @{ Name = 'NuGet packages'; Paths = @("$u\.nuget\packages"); Safe = $false; Procs = @(); Note = 'rebuilt by restore, but slow' },
        @{ Name = 'Gradle caches'; Paths = @("$u\.gradle\caches"); Safe = $false; Procs = @(); Note = 'rebuilt, but slow' },
        @{ Name = 'Maven repository'; Paths = @("$u\.m2\repository"); Safe = $false; Procs = @(); Note = 'rebuilt, but slow' }
    )
}
function Invoke-SpaceAnalyzer {
    Say '[+] Free up space' Cyan
    $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    Say ('  System drive: {0:N1} GB free of {1:N0} GB' -f ($drive.Free / 1GB), (($drive.Free + $drive.Used) / 1GB)) White
    $cands = @(Get-SpaceCandidates)
    $items = @($cands | ForEach-Object { [pscustomobject]@{ Paths = @($_.Paths); Limit = 12 } })
    $sizes = Measure-PathsParallel $items 40 4
    $skippedCands = 0
    for ($i = 0; $i -lt $cands.Count; $i++) {
        if ($null -eq $sizes[$i]) { $cands[$i].Size = [int64]0; $skippedCands++ } else { $cands[$i].Size = [int64]$sizes[$i] }
    }
    if ($skippedCands -gt 0) { Say "  ($skippedCands location(s) were not measured to keep this quick)" DarkGray }
    $found = @($cands | Where-Object { $_.Size -gt 5MB } | Sort-Object { $_.Size } -Descending)
    Write-Host ''
    if ($found.Count -eq 0) { Say '  No big caches found.' Green }
    $i = 0
    foreach ($c in $found) {
        $i++
        $tag = '[safe to clean]'
        $col = 'Green'
        if (-not $c.Safe) { $tag = '[review by hand]'; $col = 'Yellow' }
        Say ('  {0,2}. {1,-30}{2,10}  {3}  {4}' -f $i, $c.Name, (Format-Size $c.Size), $tag, $c.Note) $col
    }
    $safe = @($found | Where-Object { $_.Safe })
    $freed = [int64]0
    if ($safe.Count -gt 0) {
        $ans = 'A'
        if (-not $script:AutoYes) { $ans = (Read-Host '  Clean: A = all safe ones, numbers (1,3), Enter = skip').Trim().ToUpper() }
        $chosen = @()
        if ($ans -eq 'A') { $chosen = $safe }
        elseif ($ans) {
            foreach ($tok in ($ans -split ',')) {
                $k = 0
                if ([int]::TryParse($tok.Trim(), [ref]$k) -and $k -ge 1 -and $k -le $found.Count -and $found[$k - 1].Safe) { $chosen += $found[$k - 1] }
            }
        }
        foreach ($c in $chosen) {
            if ($c.Procs.Count -gt 0 -and -not (Confirm-CloseApps $c.Procs "It must be closed to clean $($c.Name).")) { Say "  [--]  $($c.Name) skipped (app left open)" DarkGray; continue }
            $script:LastRmErrors = @()
            Invoke-Act "Clean $($c.Name) ($(Format-Size $c.Size))" {
                foreach ($p in $c.Paths) {
                    if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue -ErrorVariable ev1; $script:LastRmErrors += @($ev1) }
                    elseif (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable ev2; $script:LastRmErrors += @($ev2) }
                }
            }
            if ($script:LastRmErrors.Count -gt 0) { Say "        $($script:LastRmErrors.Count) item(s) in use were left in place" DarkGray }
            $freed += $c.Size
        }
    }
    # Hibernation file
    $hib = $false
    try { $hib = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled -eq 1) } catch {}
    if ($hib) {
        $hs = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
        $sz = 'a few GB'
        if ($hs) { $sz = Format-Size $hs.Length }
        Say "  Hibernation file reserves $sz. Turning hibernation off frees it (also disables Fast Startup)." Yellow
        if ($script:DryRun -or (Ask '  Turn hibernation off?')) {
            Invoke-Act 'Turn hibernation off' { powercfg /hibernate off; if ($LASTEXITCODE -ne 0) { throw 'powercfg /hibernate off failed' }; Add-Journal @{ Type = 'hibernate' } }
        }
    }
    # CompactOS
    $already = @(Get-Journal | Where-Object { $_.Type -eq 'compactos' }).Count -gt 0
    if (-not $already -and -not $script:AutoYes) {
        Say '  Windows file compression (CompactOS) saves about 2 GB on the system drive. It takes 10-20 minutes, and old CPUs may feel slightly slower.' Yellow
        if (Ask '  Compress Windows files now?') {
            Invoke-Act 'Compress Windows files (CompactOS, takes a while)' { compact.exe /compactOS:always | Out-Null; if ($LASTEXITCODE -ne 0) { throw "compact exit code $LASTEXITCODE" }; Add-Journal @{ Type = 'compactos' } }
        }
    }
    # Docker
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $job = Start-Job -ScriptBlock { docker system df 2>&1 }
        if (Wait-Job $job -Timeout 25) {
            $df = @(Receive-Job $job)
            if ($df.Count -gt 0 -and -not (($df -join ' ') -match 'error|cannot connect|failed')) {
                Say '  Docker disk usage:' White
                foreach ($ln in $df) { Say "    $ln" DarkGray }
                if ($script:DryRun -or (Ask '  Remove stopped containers, unused networks and dangling images (docker system prune)?')) {
                    Invoke-Act 'docker system prune' { docker system prune -f | Out-Null; if ($LASTEXITCODE -ne 0) { throw "docker exit code $LASTEXITCODE" } }
                }
            } else { Say '  Docker is installed but not running. Start Docker Desktop to see and trim its usage.' DarkGray }
        } else { Stop-Job $job; Say '  Docker did not answer in time. Start Docker Desktop and retry.' DarkGray }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    # Biggest folders in the user profile
    Write-Host ''
    Say '  Biggest folders in your user profile (for you to decide):' White
    $rows = @()
    $dirs = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -ErrorAction SilentlyContinue)) {
        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $d.Name -eq 'AppData') { continue }   # skip junctions and AppData itself
        $dirs += @{ Path = $d.FullName; Limit = 5 }
    }
    foreach ($b in @('AppData\Local', 'AppData\Roaming')) {
        foreach ($s in @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE $b) -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $dirs += @{ Path = $s.FullName; Limit = 3 }
        }
    }
    $ditems = @($dirs | ForEach-Object { [pscustomobject]@{ Paths = @($_.Path); Limit = $_.Limit } })
    $dsizes = Measure-PathsParallel $ditems 40 4
    $k = 0
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        if ($null -ne $dsizes[$i]) { $k++; $rows += [pscustomobject]@{ Name = $dirs[$i].Path; Size = [int64]$dsizes[$i] } }
    }
    if ($k -lt $dirs.Count) { Say ("  (measured {0} of {1} folders to keep this quick; sizes are minimums)" -f $k, $dirs.Count) DarkGray }
    foreach ($r in ($rows | Where-Object { $_.Name -notmatch '\\AppData$' } | Sort-Object Size -Descending | Select-Object -First 10)) { Say ('    {0,10}  {1}' -f (Format-Size $r.Size), $r.Name) DarkGray }
    if ($freed -gt 0 -and -not $script:DryRun) { Say ('  Cleaned about {0}.' -f (Format-Size $freed)) Green; Write-Log "Space analyzer cleaned $(Format-Size $freed)" }
    Write-Wrapped 'Tip: move big personal files (videos, installers, archives) to the other drive, and uninstall programs you no longer use from Settings > Apps.' 2 78 DarkGray
}

# ================================================================ DISK HEALTH TREND
$script:DiskHist = Join-Path $script:Dir 'turbo_disk_history.json'
function Scan-DiskHealth {
    try {
        foreach ($p in @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
            if ($p.PredictFailure) { Add-Finding "smart-$($p.InstanceName)" 'HIGH' 'A drive predicts that it will fail (SMART)' 'Back up your data now and plan to replace that drive.' }
        }
    } catch {}
    $hist = @{}
    if (Test-Path $script:DiskHist) {
        try { $o = Get-Content $script:DiskHist -Raw | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $hist[$p.Name] = $p.Value } } catch {}
    }
    $new = @{}
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if (-not $rc) { continue }
            $name = [string]$pd.FriendlyName
            $snap = @{ Time = (Get-Date).ToString('o'); Temp = $rc.Temperature; Wear = $rc.Wear; ReadUnc = $rc.ReadErrorsUncorrected; WriteUnc = $rc.WriteErrorsUncorrected; Hours = $rc.PowerOnHours }
            $new[$name] = $snap
            $old = $hist[$name]
            if ($old) {
                foreach ($f in @(@('ReadUnc', 'read'), @('WriteUnc', 'write'))) {
                    $a = $old.($f[0]); $b = $snap[$f[0]]
                    if ($null -ne $a -and $null -ne $b -and [int64]$b -gt [int64]$a) {
                        Add-Finding "diskerr-$name-$($f[0])" 'HIGH' "Disk '$name': uncorrected $($f[1]) errors grew from $a to $b" "Since $(([datetime]$old.Time).ToString('MM-dd HH:mm')). Rising error counts mean the drive is degrading. Back up now."
                    }
                }
            }
            if ($snap.Temp -and [int]$snap.Temp -gt 55) { Add-Finding "disktemp-$name" 'MED' "Disk '$name' is hot ($($snap.Temp) C)" 'Heat shortens drive life. Check airflow and dust.' }
        }
    } catch {}
    foreach ($k in $hist.Keys) { if (-not $new.ContainsKey($k)) { $new[$k] = $hist[$k] } }
    if ($new.Count -gt 0 -and -not $script:DryRun) { try { $new | ConvertTo-Json -Depth 4 | Set-Content -Path $script:DiskHist -Encoding UTF8 } catch {} }
}

# ================================================================ SECURITY CHECK
function Scan-Security {
    try {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
        if ($off.Count -gt 0) { Add-Finding 'fw-off' 'HIGH' ('Windows Firewall is off for: ' + (($off | ForEach-Object { $_.Name }) -join ', ')) 'Without it, other computers on the network can reach every open port on this PC.' 'FirewallOn' @($off | ForEach-Object { [string]$_.Name }) }
    } catch {}
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop
        if ($f.State -eq 'Enabled') { Add-Finding 'smb1' 'HIGH' 'SMBv1 is enabled' 'An obsolete file-sharing protocol used by ransomware worms such as WannaCry. Almost nothing needs it today. Needs a restart to apply.' 'Smb1Off' }
    } catch {}
    try {
        if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop).fDenyTSConnections -eq 0) {
            Add-Finding 'rdp' 'MED' 'Remote Desktop is enabled' 'Anyone who can reach this PC can try to guess a password. Turn it off if you do not use it.' 'RdpOff'
        }
    } catch {}
    try {
        $g = Get-LocalUser -Name Guest -ErrorAction Stop
        if ($g.Enabled) { Add-Finding 'guest' 'MED' 'The Guest account is enabled' 'It lets anyone use the PC without a password.' 'GuestOff' }
    } catch {}
    try {
        $skip = @(135, 139, 445, 5040, 7680)
        $ls = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { @('0.0.0.0', '::') -contains $_.LocalAddress -and $_.LocalPort -lt 49152 -and $skip -notcontains $_.LocalPort })
        $items = @()
        foreach ($c in ($ls | Sort-Object LocalPort -Unique)) {
            $pn = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            $items += "$($c.LocalPort) ($pn)"
        }
        if ($items.Count -gt 0) { Add-Finding 'ports' 'INFO' "$($items.Count) program(s) listen on every network interface" ("Port (program): " + ($items -join ', ') + '. Make sure you recognize them and that the firewall is on.') }
    } catch {}
    $rem = @()
    foreach ($n in 'AnyDesk', 'TeamViewer', 'rustdesk', 'UltraViewer', 'AweSun', 'ToDesk') { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $rem += $n } }
    if ($rem.Count -gt 0) { Add-Finding 'remote-tools' 'INFO' ('Remote-control software is running: ' + ($rem -join ', ')) 'Use a strong unattended-access password, and close it when you are not using it.' }
    try {
        $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            $days = ((Get-Date) - $hf.InstalledOn).TotalDays
            if ($days -gt 60) { Add-Finding 'patch-age' 'MED' ('The last security update was {0:N0} days ago' -f $days) 'Known holes stay open until updates install. On Windows 10 this may be because support ended: see the Windows 10 finding.' }
        }
    } catch {}
}

# ================================================================ DRIVERS: BACKUP / RESTORE
function Get-BackupRoot {
    $v = $null
    try { $v = Get-Volume -ErrorAction Stop | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and ("$($_.DriveLetter):" -ne $env:SystemDrive) } | Sort-Object SizeRemaining -Descending | Select-Object -First 1 } catch {}
    if ($v) { return "$($v.DriveLetter):\TurboBackup" }
    return (Join-Path $script:Dir 'turbo_backups')
}
function Invoke-DriverBackup {
    Say '[+] Back up installed drivers' Cyan
    $dest = Join-Path (Get-BackupRoot) ('Drivers_' + (Get-Date -Format 'yyyyMMdd_HHmm'))
    Say "  Destination: $dest" White
    Write-Wrapped 'Exports every third-party driver (touchpad, Wi-Fi, graphics...) so you can reinstall them after a Windows reset, even if the maker removed old downloads.' 2 78 DarkGray
    if (-not $script:DryRun -and -not (Ask '  Back up the drivers now?')) { return }
    Invoke-Act 'Export drivers (Export-WindowsDriver)' {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Export-WindowsDriver -Online -Destination $dest -ErrorAction Stop | Out-Null
    }
    if (-not $script:DryRun -and (Test-Path $dest)) {
        $n = @(Get-ChildItem -Path $dest -Directory -ErrorAction SilentlyContinue).Count
        Say ('  {0} driver package(s), {1}. To restore later use option B here.' -f $n, (Format-Size (Get-PathBytes $dest 60))) Green
    }
}
function Invoke-DriverRestore {
    Say '[+] Restore drivers from a backup' Cyan
    $root = Get-BackupRoot
    $sets = @(Get-ChildItem -Path $root -Directory -Filter 'Drivers_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($sets.Count -eq 0) { Say "  No driver backups found in $root" Yellow; return }
    for ($i = 0; $i -lt $sets.Count; $i++) { Say ('  {0}. {1}' -f ($i + 1), $sets[$i].FullName) }
    $pick = 1
    if (-not $script:AutoYes) { $a = Read-Host '  Which one? [1]'; if ($a -match '^\d+$') { $pick = [int]$a } }
    if ($pick -lt 1 -or $pick -gt $sets.Count) { return }
    $path = $sets[$pick - 1].FullName
    if (-not $script:DryRun -and -not (Ask "  Install all drivers from this backup?")) { return }
    Invoke-Act "Install drivers from $path" {
        pnputil.exe /add-driver "$path\*.inf" /subdirs /install | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw "pnputil exit code $LASTEXITCODE" }
    }
}
function Invoke-DriverMenu {
    if ($script:AutoYes) { Invoke-DriverBackup; Invoke-DriverRestore; return }
    while ($true) {
        Say ''
        Say '[ DRIVERS ]' Cyan
        Say '  A. Back up installed drivers'
        Say '  B. Restore drivers from a backup'
        Say '  0. Back'
        switch ((Read-Host '>> Select').Trim().ToUpper()) { 'A' { Invoke-DriverBackup } 'B' { Invoke-DriverRestore } '0' { return } }
    }
}

# ================================================================ NETWORK TOOLS (DNS, hosts, Wi-Fi channels)
$script:DnsProviders = @(
    @{ N = 'Cloudflare'; S = @('1.1.1.1', '1.0.0.1') },
    @{ N = 'Google'; S = @('8.8.8.8', '8.8.4.4') },
    @{ N = 'Quad9'; S = @('9.9.9.9', '149.112.112.112') }
)
function Get-ActiveAdapters { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }
function Invoke-DnsBenchmark {
    Say '[+] DNS speed test (5 lookups per provider)' Cyan
    $names = 'microsoft.com', 'wikipedia.org', 'github.com', 'cloudflare.com', 'bbc.com'
    $rows = @()
    $cur = @(Get-ActiveAdapters | ForEach-Object { (Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses } | Select-Object -First 1)
    $all = @($script:DnsProviders)
    if ($cur.Count -gt 0 -and $cur[0]) { $all += @{ N = 'Current DNS'; S = @($cur[0]) } }
    foreach ($p in $all) {
        Working-Begin "Testing $($p.N) ..."
        $ms = @()
        foreach ($n in $names) {
            try { $t = Measure-Command { Resolve-DnsName -Name $n -Server $p.S[0] -Type A -DnsOnly -ErrorAction Stop | Out-Null }; $ms += $t.TotalMilliseconds } catch {}
        }
        Working-End
        $avg = $null
        if ($ms.Count -gt 0) { $avg = [math]::Round(($ms | Measure-Object -Average).Average) }
        $rows += [pscustomobject]@{ Name = $p.N; Avg = $avg; Ok = $ms.Count }
    }
    foreach ($r in ($rows | Sort-Object { if ($null -eq $_.Avg) { 99999 } else { $_.Avg } })) {
        $t = 'failed'
        if ($null -ne $r.Avg) { $t = "$($r.Avg) ms ($($r.Ok)/5 answered)" }
        Say ('  {0,-14}{1}' -f $r.Name, $t)
    }
    Say '  Lower is faster. VPN tools (Cloudflare WARP, Tailscale) may override DNS while they run.' DarkGray
}
function Set-DnsProvider($Provider) {
    foreach ($a in @(Get-ActiveAdapters)) {
        $prev = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $auto = $true
        try { $ns = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction Stop).NameServer; if ($ns) { $auto = $false } } catch {}
        $label = $Provider.N
        Invoke-Act "DNS of $($a.Name) -> $label" {
            Add-Journal @{ Type = 'dns'; Index = [int]$a.ifIndex; Auto = $auto; Previous = $prev }
            if ($Provider.Auto) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop }
            else { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $Provider.S -ErrorAction Stop }
            Clear-DnsClientCache
        }
    }
}
function Invoke-HostsCheck {
    Say '[+] Hosts file check' Cyan
    $h = "$env:SystemRoot\System32\drivers\etc\hosts"
    $ok = $false
    try { $null = Get-Content -LiteralPath $h -ErrorAction Stop; $ok = $true } catch {}
    if ($ok) { Say '  The hosts file is readable.' Green; return }
    Say '  The hosts file is missing or unreadable (matches the DNS-Client errors in the event log).' Yellow
    if (-not $script:DryRun -and -not (Ask '  Recreate it with the Windows default content?')) { return }
    Invoke-Act 'Recreate the hosts file' {
        if (Test-Path $h) { Copy-Item $h "$h.bak_$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue }
        Set-Content -Path $h -Value @('# Default hosts file recreated by Turbo Optimizer', '127.0.0.1       localhost', '::1             localhost') -Encoding ASCII -ErrorAction Stop
    }
}
function Invoke-WifiChannels {
    Say '[+] Wi-Fi channel check' Cyan
    $lines = @(netsh wlan show networks mode=bssid 2>$null)
    $nets = @()
    $ssid = ''
    foreach ($ln in $lines) {
        if ($ln -match '^\s*SSID\s+\d+\s*:\s*(.*)$') { $ssid = $Matches[1].Trim() }
        elseif ($ln -match '^\s*Signal\s*:\s*(\d+)\s*%') { $sig = [int]$Matches[1] }
        elseif ($ln -match '^\s*Channel\s*:\s*(\d+)\s*$') { $nets += [pscustomobject]@{ Ssid = $ssid; Channel = [int]$Matches[1]; Signal = $sig } }
    }
    if ($nets.Count -eq 0) { Say '  Could not read nearby networks (Wi-Fi off, or Windows is not in English: this check reads English labels).' Yellow; return }
    $mine = ''
    $cur = @(netsh wlan show interfaces 2>$null | Where-Object { $_ -match '^\s*Channel\s*:\s*(\d+)' })
    if ($cur.Count -gt 0 -and $cur[0] -match '(\d+)\s*$') { $mine = [int]$Matches[1] }
    $two = @($nets | Where-Object { $_.Channel -le 14 })
    Say "  Networks seen: $($nets.Count)   on 2.4 GHz: $($two.Count)   your channel: $mine" White
    if ($two.Count -gt 0) {
        $load = @{}
        foreach ($c in 1, 6, 11) { $load[$c] = 0 }
        foreach ($n in $two) { foreach ($c in 1, 6, 11) { if ([math]::Abs($n.Channel - $c) -le 4) { $load[$c] += $n.Signal } } }
        foreach ($c in 1, 6, 11) { Say ("    Channel {0,2}: load {1}" -f $c, $load[$c]) }
        $best = ($load.GetEnumerator() | Sort-Object Value | Select-Object -First 1).Key
        Say "  Least crowded 2.4 GHz channel: $best. Change it in your router's admin page (this tool cannot do it)." Green
    }
    $five = @($nets | Where-Object { $_.Channel -gt 14 })
    if ($five.Count -gt 0) { Say "  5 GHz networks seen: $($five.Count). If your PC and router support 5 GHz, it is usually faster and less crowded." DarkGray }
}
function Invoke-NetworkTools {
    if ($script:AutoYes) { Invoke-DnsBenchmark; Invoke-HostsCheck; Invoke-WifiChannels; return }
    while ($true) {
        Say ''
        Say '[ NETWORK TOOLS ]' Cyan
        Say '  A. DNS speed test'
        Say '  B. Switch DNS (Cloudflare / Google / Quad9 / automatic, reversible)'
        Say '  C. Check the hosts file'
        Say '  D. Wi-Fi channel check'
        Say '  0. Back'
        switch ((Read-Host '>> Select').Trim().ToUpper()) {
            'A' { Invoke-DnsBenchmark }
            'B' {
                for ($i = 0; $i -lt $script:DnsProviders.Count; $i++) { Say ("  {0}. {1} ({2})" -f ($i + 1), $script:DnsProviders[$i].N, ($script:DnsProviders[$i].S -join ', ')) }
                Say '  4. Automatic (from your router)'
                $c = Read-Host '  Choose'
                if ($c -match '^[123]$') { Set-DnsProvider $script:DnsProviders[[int]$c - 1] }
                elseif ($c -eq '4') { Set-DnsProvider @{ N = 'Automatic'; Auto = $true } }
            }
            'C' { Invoke-HostsCheck }
            'D' { Invoke-WifiChannels }
            '0' { return }
        }
    }
}

# ================================================================ STARTUP: DELAY INSTEAD OF DISABLE
function Invoke-DelayStartup($It, [int]$Minutes) {
    $tn = 'TurboOpt Delayed - ' + ($It.Name -replace '[^\w\.\- ]', '_')
    Invoke-Act "Start $($It.Name) $Minutes min after sign-in instead of at once" {
        $cmd = [string]$It.Command
        if ($It.Kind -eq 'Folder') { $cmd = '"' + $cmd + '"' }
        $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c start "" {0}' -f $cmd)
        $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $trg.Delay = ('PT{0}M' -f $Minutes)
        $prin = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $tn -Action $act -Trigger $trg -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
        if ($It.Kind -eq 'RunKey') {
            $val = (Get-ItemProperty -Path $It.Location -Name $It.Name).($It.Name)
            Add-Journal @{ Type = 'startup-delayed'; Kind = 'RunKey'; Location = $It.Location; Name = $It.Name; Value = [string]$val; Task = $tn }
            Remove-ItemProperty -Path $It.Location -Name $It.Name -ErrorAction Stop
        } else {
            $dest = Join-Path $script:BackupDir 'startup'
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            $bk = Join-Path $dest ((Get-Date -Format 'yyyyMMddHHmmss') + '_' + $It.Name)
            Add-Journal @{ Type = 'startup-delayed'; Kind = 'Folder'; Original = $It.Command; Backup = $bk; Name = $It.Name; Task = $tn }
            Move-Item -LiteralPath $It.Command -Destination $bk -ErrorAction Stop
        }
    }
}

# ================================================================ DISK AND BOOT (MBR / GPT, BIOS / UEFI, AHCI, TRIM, Windows 11 readiness)
function Get-FirmwareMode {
    try { $t = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType; if ($t -eq 2) { return 'UEFI' }; if ($t -eq 1) { return 'BIOS' } } catch {}
    try {
        $b = (bcdedit /enum '{current}' 2>$null) -join ' '
        if ($b -match 'winload\.efi') { return 'UEFI' }
        if ($b -match 'winload\.exe') { return 'BIOS' }
    } catch {}
    try { [void](Confirm-SecureBootUEFI -ErrorAction Stop); return 'UEFI' } catch { if ("$($_.Exception.Message)" -match 'not supported on this platform') { return 'BIOS' } }
    return 'unknown'
}
function Get-SataMode {
    $names = @()
    try { $names = @(Get-CimInstance Win32_IDEController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) } catch {}
    $nvme = $false
    try { $nvme = [bool](Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.BusType)" -eq 'NVMe' }) } catch {}
    if ($names | Where-Object { $_ -match 'AHCI' }) { return 'AHCI' }
    if ($names | Where-Object { $_ -match 'RAID|Rapid Storage|RST' }) { return 'RAID' }
    if ($names | Where-Object { $_ -match 'IDE|Dual Channel|ATA' }) { return 'IDE' }
    if ($nvme) { return 'NVMe' }
    return 'unknown'
}
function Get-TrimOn {
    try { $o = (fsutil behavior query DisableDeleteNotify) -join ' '; if ($o -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { return ($Matches[1] -eq '0') } } catch {}
    return $null
}
function Get-CpuGeneration([string]$Name) {
    if ($Name -match 'i[3579]-(\d{4,5})') { $n = $Matches[1]; if ($n.Length -eq 5) { return [int]$n.Substring(0, 2) } else { return [int]$n.Substring(0, 1) } }
    if ($Name -match 'Ryzen\s*[3579]\s*(\d)\d{3}') { return [int]$Matches[1] }   # Ryzen 2000 -> 2
    return $null
}
function Get-BootInfo {
    $o = [ordered]@{}
    $o.Firmware = Get-FirmwareMode
    $sb = 'unsupported'
    try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $sb = 'on' } else { $sb = 'off' } } catch {}
    $o.SecureBoot = $sb
    $o.TpmSpec = ''
    try { $w = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop; if ($w) { $o.TpmSpec = [string]$w.SpecVersion } } catch {}
    $disks = @()
    $sysNum = $null
    try { $sysNum = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop).DiskNumber } catch {}
    $phys = @{}
    try { foreach ($p in @(Get-PhysicalDisk -ErrorAction Stop)) { $phys[[int]$p.DeviceId] = $p } } catch {}
    try {
        foreach ($d in @(Get-Disk -ErrorAction Stop)) {
            $p = $phys[[int]$d.Number]
            $mt = 'unknown'; if ($p) { $mt = [string]$p.MediaType }
            $disks += [pscustomobject]@{ Number = [int]$d.Number; Name = [string]$d.FriendlyName; SizeGB = [math]::Round($d.Size / 1GB); Style = [string]$d.PartitionStyle; Media = $mt; Bus = [string]$d.BusType; System = ($d.Number -eq $sysNum) }
        }
    } catch {}
    $o.Disks = $disks
    $o.SataMode = Get-SataMode
    $o.Trim = Get-TrimOn
    $o.CpuName = ''
    try { $o.CpuName = [string](Get-CimInstance Win32_Processor | Select-Object -First 1).Name } catch {}
    $o.RamGB = 0
    try { $o.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch {}
    $o.BiosYear = 0; $o.BiosVersion = ''
    try { $b = Get-CimInstance Win32_BIOS | Select-Object -First 1; $o.BiosVersion = [string]$b.SMBIOSBIOSVersion; if ($b.ReleaseDate) { $o.BiosYear = ([datetime]$b.ReleaseDate).Year } } catch {}
    $o.BiosApi = Get-BiosApi
    return [pscustomobject]$o
}
# Reasons this PC cannot run Windows 11 (an approximation of Microsoft's rules; PC Health Check is the official answer).
function Get-Win11Blockers($I) {
    $r = @()
    if ($I.Firmware -eq 'BIOS') { $r += 'the PC starts in legacy BIOS mode (Windows 11 needs UEFI)' }
    elseif ($I.Firmware -eq 'UEFI' -and $I.SecureBoot -eq 'unsupported') { $r += 'Secure Boot is not available' }
    if (-not ($I.TpmSpec -match '^2\.0')) { $r += 'no TPM 2.0 was found' }
    if ($I.RamGB -gt 0 -and $I.RamGB -lt 4) { $r += "only $($I.RamGB) GB of memory (4 GB needed)" }
    $sys = @($I.Disks | Where-Object { $_.System })[0]
    if ($sys -and $sys.SizeGB -lt 64) { $r += "the system disk is $($sys.SizeGB) GB (64 GB needed)" }
    $g = Get-CpuGeneration $I.CpuName
    if ($null -ne $g -and $g -lt 8 -and $I.CpuName -match 'Intel') { $r += "the CPU is Intel generation $g (generation 8 or newer is needed)" }
    if ($null -ne $g -and $g -lt 2 -and $I.CpuName -match 'Ryzen') { $r += 'the CPU is an old Ryzen (Ryzen 2000 or newer is needed)' }
    return $r
}
function Scan-Boot {
    $I = Get-BootInfo
    $sys = @($I.Disks | Where-Object { $_.System })[0]
    $hasSsd = [bool](@($I.Disks | Where-Object { $_.Media -eq 'SSD' }).Count)
    if ($I.SataMode -eq 'IDE') {
        Add-Finding 'sata-ide' 'MED' 'The disk controller runs in IDE mode instead of AHCI' 'AHCI is the normal SATA mode. In IDE mode an SSD loses speed and TRIM (it slows down over time) and hard drives lose command queuing. Changing it in the BIOS without preparing Windows first makes Windows fail to start, so use the preparation step first, then change the SATA mode in the BIOS.' 'PrepareAhci'
    }
    if ($hasSsd -and $I.Trim -eq $false) {
        Add-Finding 'trim-off' 'MED' 'TRIM is turned off although you have an SSD' 'TRIM lets Windows tell the SSD which blocks are free, which keeps it fast and healthy. Turning it on is safe and can be undone.' 'TrimOn'
    }
    if ($I.Firmware -eq 'BIOS' -and $sys) {
        $d = "This PC starts in legacy BIOS mode and its system disk uses MBR. That works fine for Windows 10, but it limits disks to 2 TB, has no Secure Boot, and Windows 11 cannot be installed. Moving to UEFI + GPT needs a PC whose BIOS offers a UEFI option."
        if ($I.BiosYear -gt 0 -and $I.BiosYear -lt 2014) { $d += " The BIOS of this PC dates from $($I.BiosYear). PCs of that age almost always have no UEFI option, so leave it as it is." ; Add-Finding 'boot-legacy' 'INFO' 'Legacy BIOS + MBR (normal for this PC)' $d }
        else {
            $d += " The BIOS here dates from $($I.BiosYear), so it may support UEFI: open the BIOS menu and look for Boot Mode / UEFI / CSM / Legacy."
            Add-Finding 'boot-convertible' 'INFO' 'This PC may be able to move from legacy BIOS + MBR to UEFI + GPT' $d 'ConvertGpt'
        }
    }
    foreach ($d in @($I.Disks | Where-Object { $_.Style -eq 'MBR' -and $_.SizeGB -gt 2200 })) {
        Add-Finding "mbr-big-$($d.Number)" 'MED' ("Disk {0} ({1} GB) uses MBR: only the first 2 TB can be used" -f $d.Number, $d.SizeGB) 'MBR cannot address more than 2 TB. A data disk can be converted to GPT after you copy its files off it (Disk Management > Convert to GPT Disk). Nothing is changed automatically.'
    }
    $os = ''; try { $os = [string](Get-CimInstance Win32_OperatingSystem).Caption } catch {}
    if ($os -match 'Windows 10') {
        $b = Get-Win11Blockers $I
        if ($b.Count -eq 0) { Add-Finding 'win11-ready' 'INFO' 'This PC looks ready for Windows 11' 'It passes the checks this tool can make (UEFI, Secure Boot, TPM 2.0, memory, disk, CPU generation). Confirm with Microsoft PC Health Check, then upgrade through Windows Update.' }
        else { Add-Finding 'win11-blocked' 'INFO' 'This PC does not meet the Windows 11 requirements' ('Blocked by: ' + ($b -join '; ') + '. This is an approximation; Microsoft PC Health Check gives the official answer. Windows 10 keeps working, so only upgrade if the PC qualifies.') }
    }
    if ($I.Firmware -eq 'UEFI' -and $I.SecureBoot -eq 'off') { Add-Finding 'secureboot-off' 'INFO' 'Secure Boot is turned off' 'Secure Boot blocks boot-time malware and is required by Windows 11. It is switched in the BIOS menu (Security or Boot tab).' }
}
function Invoke-BootCheck {
    Say '[+] Disk and boot check (read-only)' Cyan
    $I = Get-BootInfo
    $fw = switch ($I.Firmware) { 'UEFI' { 'UEFI' } 'BIOS' { 'legacy BIOS' } default { 'unknown' } }
    Say ("  Boot mode      {0}" -f $fw) White
    Say ("  Secure Boot    {0}" -f $I.SecureBoot) Gray
    $tpm = 'none found'; if ($I.TpmSpec) { $tpm = "version $($I.TpmSpec)" }
    Say ("  TPM            {0}" -f $tpm) Gray
    Say ("  SATA mode      {0}" -f $I.SataMode) Gray
    $trim = 'unknown'; if ($I.Trim -eq $true) { $trim = 'on' } elseif ($I.Trim -eq $false) { $trim = 'off' }
    Say ("  TRIM           {0}" -f $trim) Gray
    Say ("  BIOS           {0}  ({1})" -f $I.BiosVersion, $I.BiosYear) Gray
    $api = 'not available on this PC (change BIOS options in the BIOS menu)'; if ($I.BiosApi) { $api = "available ($($I.BiosApi))" }
    Say ("  BIOS from Windows  {0}" -f $api) Gray
    Say '  Disks:' White
    foreach ($d in $I.Disks) {
        $sysTag = ''; if ($d.System) { $sysTag = '  [system]' }
        Say ("    #{0}  {1,-28} {2,5} GB  {3,-4} {4}{5}" -f $d.Number, $d.Name, $d.SizeGB, $d.Style, $d.Media, $sysTag) Gray
    }
    Say '  Rule: UEFI starts from GPT disks, legacy BIOS starts from MBR disks. They must match.' DarkGray
    Say '  An SSD works with both MBR and GPT. What helps an SSD is AHCI mode and TRIM.' DarkGray
    Write-Host ''
    Invoke-Doctor -ScanOnly -Only @('Scan-Boot') -Title 'Boot check'
}
function Invoke-TrimOn {
    $prev = Get-TrimOn
    Invoke-Act 'Turn TRIM on (fsutil behavior set DisableDeleteNotify 0)' {
        Add-Journal @{ Type = 'trim'; Previous = $(if ($prev -eq $false) { 1 } else { 0 }) }
        fsutil behavior set DisableDeleteNotify 0 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "fsutil exit code $LASTEXITCODE" }
    }
}
# Makes Windows able to start with the SATA controller in AHCI mode, so the BIOS switch does not cause a boot failure.
function Invoke-PrepareAhci {
    Say '[ SWITCH TO AHCI ]' Cyan
    $mode = Get-SataMode
    if ($mode -eq 'AHCI' -or $mode -eq 'NVMe') { Say "  The disk controller already runs in $mode mode. Nothing to do." Green; return }
    if ($mode -eq 'RAID') { Say '  The controller is in RAID mode (Intel RST). Switching it needs the vendor driver; this tool does not touch it.' Yellow; return }
    Say '  Step 1 (this tool): make Windows load the AHCI driver at every start.' Gray
    Say '  Step 2 (you or the BIOS tool): change "SATA Operation / SATA Mode" from IDE (or Compatibility) to AHCI.' Gray
    Say '  Step 3: start Windows normally. If it fails, put the BIOS back to IDE and everything works as before.' Gray
    if (-not (Ask '  Prepare Windows for AHCI now?')) { return }
    $svc = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    foreach ($n in 'storahci', 'iaStorV', 'iaStorAV', 'iaStorAVC', 'amdsata', 'amdxata') {
        if (Test-Path "$svc\$n") { Set-RegJournaled "$svc\$n" 'Start' 0 "Make the $n driver start at boot" }
    }
    if (Test-Path "$svc\storahci\StartOverride") { Invoke-Act 'Remove the storahci start override' { Remove-Item "$svc\storahci\StartOverride" -Recurse -Force -ErrorAction Stop } }
    Say '  Windows is ready. Now change the SATA mode to AHCI:' Green
    if (Get-BiosApi) { Say '  - This PC exposes BIOS settings to Windows: use "BIOS settings from Windows" (experimental) to change it, or do it in the BIOS menu.' Gray }
    else { Say '  - Restart, open the BIOS menu (see "Restart into BIOS settings"), find SATA mode, choose AHCI, save and exit.' Gray }
}
# MBR -> GPT with Windows' own mbr2gpt tool. Refuses on PCs that probably cannot start from UEFI.
function Invoke-ConvertGpt {
    Say '[ CONVERT MBR TO GPT (advanced) ]' Cyan
    $I = Get-BootInfo
    $sys = @($I.Disks | Where-Object { $_.System })[0]
    if (-not $sys) { Say '  Could not find the system disk.' Red; return }
    if ($sys.Style -eq 'GPT') { Say '  The system disk already uses GPT. Nothing to do.' Green; return }
    if ($I.Firmware -eq 'UEFI') { Say '  This PC starts in UEFI mode but the disk is MBR: that is unusual. Stopping so nothing is made worse.' Yellow; return }
    $tool = Join-Path $env:SystemRoot 'System32\mbr2gpt.exe'
    if (-not (Test-Path $tool)) { Say '  mbr2gpt.exe is missing (it ships with Windows 10 version 1703 and newer).' Red; return }
    if ($I.BiosYear -gt 0 -and $I.BiosYear -lt 2014) {
        Say ("  This PC's BIOS is from {0}. PCs of that age almost always have no UEFI option, and after the conversion a legacy-only PC cannot start." -f $I.BiosYear) Red
        Say '  Refusing to convert. Keep MBR; Windows 10 works well that way.' Yellow
        return
    }
    $maySet = $false
    if ($I.BiosApi) {
        $opts = @(Get-BiosOptions $I.BiosApi | Where-Object { $_.Name -match 'Boot ?Mode|UEFI|Legacy|CSM' })
        if ($opts.Count -gt 0) { $maySet = $true; Say ("  The BIOS exposes boot-mode options ({0}): a UEFI choice exists." -f (($opts | ForEach-Object { $_.Name }) -join ', ')) Green }
    }
    if (-not $maySet) {
        Say '  Open your BIOS menu first and check that a UEFI / Boot Mode option exists. If the BIOS only offers Legacy, do not convert.' Yellow
        if (-not (Ask '  I checked: my BIOS has a UEFI option. Continue?')) { return }
    }
    Say '  Checking the disk layout (read-only)...' Gray
    $v = (cmd.exe /c "`"$tool`" /validate /disk:$($sys.Number) /allowFullOS 2>&1") -join "`n"
    $vcode = $LASTEXITCODE
    foreach ($l in ($v -split "`r?`n")) { if ($l.Trim()) { Say ("    " + $l.Trim()) DarkGray } }
    if ($vcode -ne 0) { Say '  The disk cannot be converted as it is (see above). Nothing was changed.' Red; return }
    Say '  The layout can be converted. Important:' White
    Say '  - Back up your data first. A restore point does not protect the partition table.' Yellow
    Say '  - After the conversion Windows will NOT start until the BIOS is switched to UEFI (and Legacy/CSM turned off).' Yellow
    if ($script:DryRun) { Say '  [DRY] would run: mbr2gpt /convert' DarkYellow; return }
    if ((Read-Host '  Type CONVERT (capital letters) to continue, anything else cancels').Trim() -cne 'CONVERT') { Say '  Cancelled. Nothing was changed.' Yellow; return }
    Write-Log "mbr2gpt convert disk $($sys.Number)"
    $c = (cmd.exe /c "`"$tool`" /convert /disk:$($sys.Number) /allowFullOS 2>&1") -join "`n"
    $ccode = $LASTEXITCODE
    foreach ($l in ($c -split "`r?`n")) { if ($l.Trim()) { Say ("    " + $l.Trim()) DarkGray } }
    if ($ccode -ne 0) { Add-Problem 'Convert to GPT' 'mbr2gpt reported an error' $c; Say '  The conversion failed. Do not change the BIOS; Windows still starts as before.' Red; return }
    $script:NeedReboot = $true
    Say '  Converted. NOW: restart, open the BIOS menu, set Boot Mode to UEFI (turn Legacy/CSM off), save and exit.' Green
}
# ---- BIOS settings through the maker's own Windows interface (Lenovo and HP). Experimental.
function Get-BiosApi {
    foreach ($c in @(@('Lenovo', 'root\wmi', 'Lenovo_BiosSetting'), @('HP', 'root\HP\InstrumentedBIOS', 'HP_BIOSEnumeration'), @('Dell', 'root\dcim\sysman\biosattributes', 'EnumerationAttribute'))) {
        try { if (@(Get-CimInstance -Namespace $c[1] -ClassName $c[2] -ErrorAction Stop).Count -gt 0) { return $c[0] } } catch {}
    }
    return $null
}
# "SecureBoot,Enable;[Optional:Disable,Enable]" -> @{ Name; Value; Allowed }
function ConvertFrom-LenovoSetting([string]$S) {
    $main = $S; $allowed = @()
    if ($S -match '^(.*?);\s*\[Optional:(.*)\]') { $main = $Matches[1]; $allowed = @($Matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $i = $main.IndexOf(',')
    if ($i -lt 1) { return $null }
    return @{ Name = $main.Substring(0, $i).Trim(); Value = $main.Substring($i + 1).Trim(); Allowed = $allowed }
}
function Get-BiosOptions([string]$Vendor) {
    $r = @()
    try {
        if ($Vendor -eq 'Lenovo') { foreach ($x in @(Get-CimInstance -Namespace root\wmi -ClassName Lenovo_BiosSetting -ErrorAction Stop)) { $p = ConvertFrom-LenovoSetting ([string]$x.CurrentSetting); if ($p) { $r += $p } } }
        elseif ($Vendor -eq 'HP') { foreach ($x in @(Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSEnumeration -ErrorAction Stop)) { $r += @{ Name = [string]$x.Name; Value = [string]$x.Value; Allowed = @($x.PossibleValues | ForEach-Object { [string]$_ }) } } }
        elseif ($Vendor -eq 'Dell') { foreach ($x in @(Get-CimInstance -Namespace root\dcim\sysman\biosattributes -ClassName EnumerationAttribute -ErrorAction Stop)) { $r += @{ Name = [string]$x.AttributeName; Value = (@($x.CurrentValue) -join ','); Allowed = @($x.PossibleValues | ForEach-Object { [string]$_ }) } } }
    } catch {}
    return @($r | Where-Object { $_ -and $_.Name })
}
function Set-BiosOption([string]$Vendor, [string]$Name, [string]$Value) {
    if ($Vendor -eq 'Lenovo') {
        $m = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SetBiosSetting -ErrorAction Stop
        $r = Invoke-CimMethod -InputObject $m -MethodName SetBiosSetting -Arguments @{ parameter = "$Name,$Value" } -ErrorAction Stop
        if ([string]$r.return -ne 'Success') { throw "The BIOS answered: $($r.return)" }
        $s = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SaveBiosSettings -ErrorAction Stop
        $r2 = Invoke-CimMethod -InputObject $s -MethodName SaveBiosSettings -Arguments @{ parameter = '' } -ErrorAction Stop
        if ([string]$r2.return -ne 'Success') { throw "The BIOS could not save: $($r2.return)" }
        return
    }
    if ($Vendor -eq 'HP') {
        $i = Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSSettingInterface -ErrorAction Stop
        $r = Invoke-CimMethod -InputObject $i -MethodName SetBIOSSetting -Arguments @{ Name = $Name; Value = $Value; Password = '<utf-16/>' } -ErrorAction Stop
        if ([int]$r.Return -ne 0) { throw "The BIOS answered with code $($r.Return) (a BIOS password may be set)" }
        return
    }
    throw "Changing BIOS options is not supported for $Vendor PCs by this tool."
}
function Invoke-BiosSettings {
    Say '[ BIOS SETTINGS FROM WINDOWS (experimental) ]' Cyan
    $v = Get-BiosApi
    if (-not $v) { Say '  This PC does not expose its BIOS to Windows (it needs a Lenovo, HP or Dell BIOS with the maker WMI interface). Change the options in the BIOS menu instead (see "Restart into BIOS settings").' Yellow; return }
    Say "  BIOS interface found: $v" Green
    $all = @(Get-BiosOptions $v | Where-Object { $_.Name -match 'SATA|AHCI|Secure ?Boot|Boot ?Mode|Legacy|UEFI|CSM|TPM|Fast ?Boot' })
    if ($all.Count -eq 0) { Say '  No boot-related options were found.' Yellow; return }
    $i = 0
    foreach ($o in $all) { $i++; Say ("  {0,2}. {1,-34} = {2}   [{3}]" -f $i, $o.Name, $o.Value, ($o.Allowed -join ' / ')) Gray }
    if ($v -eq 'Dell') { Say '  Dell PCs can be read here but changing options needs Dell Command | Configure; use the BIOS menu to change them.' Yellow; return }
    $pick = 0
    if (-not [int]::TryParse((Read-Host '  Which one do you want to change? (number, Enter = none) [0]').Trim(), [ref]$pick) -or $pick -lt 1 -or $pick -gt $all.Count) { return }
    $o = $all[$pick - 1]
    if ($o.Allowed.Count -eq 0) { Say '  The BIOS did not list the allowed values for this option, so it is not changed here.' Yellow; return }
    $j = 0
    foreach ($a in $o.Allowed) { $j++; Say ("  {0}. {1}" -f $j, $a) Gray }
    $vp = 0
    if (-not [int]::TryParse((Read-Host '  New value (number) [0]').Trim(), [ref]$vp) -or $vp -lt 1 -or $vp -gt $o.Allowed.Count) { return }
    $new = $o.Allowed[$vp - 1]
    Say '  A wrong BIOS value can stop Windows from starting. The previous value is saved so it can be undone from Windows, or from the BIOS menu if Windows no longer starts.' Yellow
    if (-not (Ask ("  Change {0} from '{1}' to '{2}'?" -f $o.Name, $o.Value, $new))) { return }
    $prev = $o.Value; $vendor = $v; $name = $o.Name
    Invoke-Act "Set BIOS option $name to $new" {
        Add-Journal @{ Type = 'bios'; Vendor = $vendor; Name = $name; Previous = $prev }
        Set-BiosOption $vendor $name $new
    }
    if (-not $script:DryRun) {
        $now = @(Get-BiosOptions $v | Where-Object { $_.Name -eq $name })[0]
        if ($now) { Say ("  The BIOS now reports: {0} = {1}" -f $now.Name, $now.Value) Green }
        Say '  The change takes effect after a restart.' Gray
        $script:NeedReboot = $true
    }
}
function Invoke-FirmwareReboot {
    Say '[ RESTART INTO BIOS SETTINGS ]' Cyan
    $fw = Get-FirmwareMode
    if ($fw -eq 'UEFI') {
        if (-not (Ask '  Restart now and open the firmware (BIOS) screen? Save your work first')) { return }
        if ($script:DryRun) { Say '  [DRY] would run: shutdown /r /fw /t 5' DarkYellow; return }
        Write-Log 'Restart into firmware settings'
        shutdown.exe /r /fw /t 5
        return
    }
    $maker = ''; try { $maker = [string](Get-CimInstance Win32_ComputerSystem).Manufacturer } catch {}
    Say '  This PC starts in legacy BIOS mode, so Windows cannot open the BIOS screen for you. Restart and press the key right after the power button:' Gray
    $keys = @{ 'Dell' = 'F2 (F12 for the boot menu)'; 'HP' = 'F10 or Esc (F9 for the boot menu)'; 'Hewlett' = 'F10 or Esc (F9 for the boot menu)'; 'LENOVO' = 'F1 or F2 (Enter, then F1, on some models)'; 'ASUS' = 'Del or F2 (F8 for the boot menu)'; 'Acer' = 'F2 or Del'; 'MSI' = 'Del'; 'Gigabyte' = 'Del' }
    $hit = $null
    foreach ($k in $keys.Keys) { if ($maker -match $k) { $hit = $k } }
    if ($hit) { Say ("  Your PC ({0}): {1}" -f $maker, $keys[$hit]) Green } else { Say '  Common keys: F2, Del, F10, F1, Esc. The maker logo screen usually shows it.' Gray }
}

# ================================================================ AUTOMATION (scheduled checks) AND HTML REPORT
function Register-MaintenanceTask {
    Invoke-Act 'Schedule weekly safe maintenance (clean temp files + health scan, asks nothing, closes nothing)' {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Maintain' -f $PSCommandPath)
        $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2pm
        $prin = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName 'TurboOptimizer Weekly Maintenance' -Action $act -Trigger $trg -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
    }
}
# ---- automatic care: off / weekly cleanup / watch and fix ----
$script:PrefsFile = Join-Path $script:Dir 'turbo_prefs.json'
$script:MonitorFile = Join-Path $script:Dir 'turbo_monitor.json'
$script:TaskWeekly = 'TurboOptimizer Weekly Maintenance'
$script:TaskMonitor = 'TurboOptimizer Monitor'
$script:TaskHealth = 'TurboOptimizer Health Check'
function Get-Prefs {
    $h = @{}
    if (Test-Path $script:PrefsFile) { try { $o = Get-Content $script:PrefsFile -Raw | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } } catch {} }
    return $h
}
function Save-Prefs($h) {
    if ($script:DryRun) { return }
    try { $h | ConvertTo-Json | Set-Content -Path $script:PrefsFile -Encoding UTF8 } catch { Add-ErrorRecord 'Save preferences' $_ }
}
function Get-AutoMode {
    if (Get-ScheduledTask -TaskName $script:TaskMonitor -ErrorAction SilentlyContinue) { return 'monitor' }
    if (Get-ScheduledTask -TaskName $script:TaskWeekly -ErrorAction SilentlyContinue) { return 'weekly' }
    return 'off'
}
function Register-MonitorTask {
    Invoke-Act 'Schedule the daily watch (checks this PC, fixes safe problems by itself, tells you about the rest)' {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Monitor' -f (Join-Path $script:Dir 'TurboOptimizer.ps1'))
        $logon = New-ScheduledTaskTrigger -AtLogOn
        $logon.Delay = 'PT10M'
        $trg = @((New-ScheduledTaskTrigger -Daily -At 1pm), $logon)
        $prin = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $script:TaskMonitor -Action $act -Trigger $trg -Principal $prin -Settings $set -Force -ErrorAction Stop | Out-Null
    }
}
# Sets what the tool does on its own. Mode: off, weekly (clean every week) or monitor (daily check + safe fixes + a notification).
function Set-AutoCare([string]$Mode) {
    if ($Mode -notin 'off', 'weekly', 'monitor') { Say "  Unknown mode: $Mode" Red; return }
    foreach ($t in $script:TaskWeekly, $script:TaskMonitor, $script:TaskHealth) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Invoke-Act "Remove the old task $t" { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop } }
    }
    if ($Mode -eq 'weekly') { Register-MaintenanceTask }
    if ($Mode -eq 'monitor') { Register-MonitorTask }
    if ($script:DryRun) { Say '  Preview mode is on: nothing was changed.' DarkYellow; return }
    $p = Get-Prefs
    $p['Asked'] = $true
    $p['AutoMode'] = $Mode
    Save-Prefs $p
    $txt = @{ off = 'Automatic care is off.'; weekly = 'Weekly cleanup is on (every Sunday, asks nothing, closes nothing).'; monitor = 'Watch and fix is on: a daily check that fixes safe problems and tells you about the rest.' }
    Say ('  ' + $txt[$Mode]) Green
    Write-Log "Automatic care set to $Mode"
}
function Send-Toast([string]$Title, [string]$Text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $t1 = [Security.SecurityElement]::Escape($Title); $t2 = [Security.SecurityElement]::Escape($Text)
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t1</text><text>$t2</text></binding></visual></toast>")
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toast)
    } catch { Write-Log "Notification failed: $($_.Exception.Message)" }
}
# The daily watch: scan, fix only the safe and reversible kinds of problems, notify about the rest.
function Invoke-MonitorRun {
    $script:Unattended = $true
    $script:Plat = Get-Platform
    Write-Log 'Monitor run started'
    $safe = @('Clean', 'ResyncTime', 'FlushDns', 'DefenderSigs', 'ServiceStart')
    Invoke-Doctor -ScanOnly
    $fixed = @(); $attention = @()
    foreach ($f in @($script:Findings)) {
        if ($f.Sev -eq 'INFO') { continue }
        if ($f.Fix -and ($safe -contains $f.Fix)) {
            $before = $script:Problems.Count
            try {
                if ($f.Fix -eq 'Clean') { Invoke-Clean -Auto } else { Invoke-Fix $f }
                if ($script:Problems.Count -eq $before) { $fixed += $f.Title; if ($f.AckKey) { Set-Ack $f.AckKey } } else { $attention += $f }
            } catch { $attention += $f }
        } else { $attention += $f }
    }
    $serious = @($attention | Where-Object { $_.Sev -eq 'HIGH' })
    $sig = (@($serious | ForEach-Object { $_.Title }) | Sort-Object) -join '|'
    $last = $null
    if (Test-Path $script:MonitorFile) { try { $last = Get-Content $script:MonitorFile -Raw | ConvertFrom-Json } catch {} }
    if (-not $script:DryRun) { try { @{ Time = (Get-Date).ToString('o'); Fixed = $fixed; Attention = @($attention | ForEach-Object { $_.Title }); Signature = $sig } | ConvertTo-Json | Set-Content -Path $script:MonitorFile -Encoding UTF8 } catch {} }
    $msg = @()
    if ($fixed.Count -gt 0) { $msg += ('Fixed {0} problem(s) by itself.' -f $fixed.Count) }
    if ($serious.Count -gt 0 -and (-not $last -or $last.Signature -ne $sig)) { $msg += ('{0} serious problem(s) need you: open Turbo Optimizer and run the Doctor.' -f $serious.Count) }
    if ($msg.Count -gt 0 -and -not $script:DryRun) { Send-Toast 'Turbo Optimizer' ($msg -join ' ') }
    Write-Log ("Monitor run finished: fixed={0} attention={1}" -f $fixed.Count, $attention.Count)
}
function Invoke-AutomationMenu {
    if ($script:AutoYes) { return }
    Say ''
    Say '[ AUTOMATIC CARE ]' Cyan
    Say ("  Now: {0}" -f (Get-AutoMode)) White
    Say '  1. Off - I run the tool myself'
    Say '  2. Weekly cleanup - cleans temporary files every week, asks nothing, closes nothing'
    Say '  3. Watch and fix - checks this PC every day, fixes safe problems by itself, notifies you about the rest'
    Say '  0. Back'
    switch ((Read-Host '>> Select').Trim()) {
        '1' { Set-AutoCare 'off' }
        '2' { Set-AutoCare 'weekly' }
        '3' { Set-AutoCare 'monitor' }
    }
}
# ---- uninstall: removes the scheduled tasks, the saved data and (for the installed copy) the app folder ----
$script:UninstallDone = $false
function Invoke-Uninstall {
    Say '[ UNINSTALL ]' Cyan
    $inst = Join-Path $env:LOCALAPPDATA 'TurboOptimizer'
    $isInstalled = ($script:Dir.TrimEnd('\') -ieq (Join-Path $inst 'app'))
    if (-not (Ask '  Remove Turbo Optimizer from this PC? Its scheduled tasks and saved data (including the undo history) are deleted. Changes already made to Windows stay unless you undo them first.')) { Say '  Cancelled. Nothing was removed.' Yellow; return }
    if ((Test-Path $script:Journal) -and (Ask '  First undo the changes this tool made to Windows?')) { Invoke-Revert }
    foreach ($t in $script:TaskWeekly, $script:TaskMonitor, $script:TaskHealth) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Invoke-Act "Remove the scheduled task $t" { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop } }
    }
    if (-not $isInstalled) {
        Say '  This copy is not the installed one, so its folder is left in place. Delete the folder yourself when you do not need it.' Yellow
        return
    }
    if ($script:DryRun) { Say "  [DRY] would delete $inst and close the app" DarkYellow; return }
    $prof = Join-Path $env:TEMP 'turbo_optimizer_browser'
    $cmd = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; for (`$i = 0; `$i -lt 12; `$i++) { Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$inst' -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '$prof' -Recurse -Force -ErrorAction SilentlyContinue; if (-not (Test-Path -LiteralPath '$inst')) { break } }"
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"{0}"' -f ($cmd -replace '"', '\"')))
    Write-Log 'Uninstall requested: the app folder is removed after this window closes'
    Say '  Turbo Optimizer is closing and will remove itself in a few seconds. Thank you for trying it.' Green
    $script:UninstallDone = $true
    if (Get-Variable -Name sync -ErrorAction SilentlyContinue) { try { $sync.Quit = $true } catch {} }
}
function Get-Ar([int[]]$Codes) { return (-join ($Codes | ForEach-Object { [string][char]$_ })) }
function Export-HtmlReport([string]$Lang = 'en') {
    Say '[+] HTML report' Cyan
    $lang = $Lang
    if (-not $script:AutoYes) { $a = (Read-Host '  Language of the headings: E = English, A = Arabic (details stay in English)').Trim().ToUpper(); if ($a -eq 'A') { $lang = 'ar' } }
    $T = @{
        en = @{ title = 'Turbo Optimizer report'; system = 'This PC'; metrics = 'Current measurements'; findings = 'Problems and advice'; changes = 'Changes made (reversible)'; problems = 'Errors in this session'; log = 'Recent log'; none = 'None'; generated = 'Created'; note = '' }
        ar = @{ title = (Get-Ar 1578,1602,1585,1610,1585,32,84,117,114,98,111,32,79,112,116,105,109,105,122,101,114); system = (Get-Ar 1605,1593,1604,1608,1605,1575,1578,32,1575,1604,1580,1607,1575,1586)
                metrics = (Get-Ar 1575,1604,1602,1610,1575,1587,1575,1578,32,1575,1604,1581,1575,1604,1610,1577); findings = (Get-Ar 1575,1604,1605,1588,1575,1603,1604,32,1608,1575,1604,1578,1608,1589,1610,1575,1578)
                changes = (Get-Ar 1575,1604,1578,1594,1610,1610,1585,1575,1578,32,1575,1604,1578,1610,32,1578,1605,1578,32,40,1602,1575,1576,1604,1577,32,1604,1604,1578,1585,1575,1580,1593,41); problems = (Get-Ar 1571,1582,1591,1575,1569,32,1607,1584,1607,32,1575,1604,1580,1604,1587,1577)
                log = (Get-Ar 1570,1582,1585,32,1575,1604,1587,1580,1604); none = (Get-Ar 1604,1575,32,1610,1608,1580,1583); generated = (Get-Ar 1578,1575,1585,1610,1582,32,1575,1604,1573,1606,1588,1575,1569)
                note = (Get-Ar 1575,1604,1593,1606,1575,1608,1610,1606,32,1576,1575,1604,1593,1585,1576,1610,1577,1548,32,1608,1575,1604,1578,1601,1575,1589,1610,1604,32,1575,1604,1578,1602,1606,1610,1577,32,1576,1575,1604,1573,1606,1580,1604,1610,1586,1610,1577) }
    }[$lang]
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    if ($script:Findings.Count -eq 0) { Invoke-Doctor -ScanOnly }
    $m = Get-Metrics
    $dir = 'ltr'
    if ($lang -eq 'ar') { $dir = 'rtl' }
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine("<!doctype html><html lang=`"$lang`" dir=`"$dir`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`"><title>$(& $enc $T.title)</title>")
    [void]$h.AppendLine('<style>:root{--bg:#fff;--fg:#1b1f24;--mut:#5b6572;--card:#f4f6f8;--hi:#c62828;--med:#b26a00;--info:#4b5563;--ok:#2e7d32}@media(prefers-color-scheme:dark){:root{--bg:#14171a;--fg:#e6e9ec;--mut:#9aa4af;--card:#1e2328;--hi:#ef5350;--med:#ffb74d;--info:#9aa4af;--ok:#66bb6a}}body{font:15px/1.5 system-ui,Segoe UI,Tahoma,sans-serif;background:var(--bg);color:var(--fg);max-width:880px;margin:0 auto;padding:24px 16px}h1{font-size:22px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid var(--card);padding-bottom:4px}.card{background:var(--card);border-radius:8px;padding:10px 14px;margin:8px 0}.HIGH{color:var(--hi)}.MED{color:var(--med)}.INFO{color:var(--info)}.mut{color:var(--mut);font-size:13px}table{border-collapse:collapse}td{padding:2px 14px 2px 0}pre{white-space:pre-wrap;font-size:12px}</style></head><body>')
    [void]$h.AppendLine("<h1>$(& $enc $T.title)</h1><p class=`"mut`">$(& $enc $T.generated): $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; v$($script:Version)</p>")
    if ($T.note) { [void]$h.AppendLine("<p class=`"mut`">$(& $enc $T.note)</p>") }
    $kind = 'desktop'
    if ($script:Plat.VM) { $kind = 'virtual machine' } elseif ($script:Plat.Laptop) { $kind = 'laptop' }
    [void]$h.AppendLine("<h2>$(& $enc $T.system)</h2><div class=`"card`">$(& $enc "$($script:Plat.Vendor) $($script:Plat.Model) - $kind")<br>$(& $enc "$($script:Plat.Caption) (build $($script:Plat.Build))")<br>$(& $enc "CPU: $($script:Sys.CPU) | RAM: $($script:Sys.RAM) GB")<br>$(& $enc ('GPU: ' + (@($script:Sys.GPU) -join ' | ')))<br>$(& $enc ('Disks: ' + (@($script:Sys.Disks) -join ' | ')))</div>")
    [void]$h.AppendLine("<h2>$(& $enc $T.metrics)</h2><div class=`"card`"><table><tr><td>Free disk</td><td>$($m.FreeGB) GB</td></tr><tr><td>RAM used</td><td>$($m.RamUsedPct) %</td></tr><tr><td>Processes</td><td>$($m.Processes)</td></tr><tr><td>Startup items</td><td>$($m.StartupItems)</td></tr><tr><td>Last boot</td><td>$($m.LastBootSec) s</td></tr></table></div>")
    [void]$h.AppendLine("<h2>$(& $enc $T.findings)</h2>")
    if ($script:Findings.Count -eq 0) { [void]$h.AppendLine("<p>$(& $enc $T.none)</p>") }
    foreach ($f in $script:Findings) { [void]$h.AppendLine("<div class=`"card`"><b class=`"$($f.Sev)`">[$($f.Sev)]</b> $(& $enc $f.Title)<div class=`"mut`">$(& $enc $f.Detail)</div></div>") }
    [void]$h.AppendLine("<h2>$(& $enc $T.changes)</h2>")
    $j = @(Get-Journal)
    if ($j.Count -eq 0) { [void]$h.AppendLine("<p>$(& $enc $T.none)</p>") }
    foreach ($e in $j) { [void]$h.AppendLine("<div class=`"card`">$(& $enc $e.Time) &mdash; $(& $enc $e.Type) $(& $enc $e.Name)</div>") }
    [void]$h.AppendLine("<h2>$(& $enc $T.problems)</h2>")
    if ($script:Problems.Count -eq 0) { [void]$h.AppendLine("<p>$(& $enc $T.none)</p>") }
    foreach ($p in $script:Problems) { [void]$h.AppendLine("<div class=`"card`"><b>[$($p.Level)]</b> $(& $enc $p.Where): $(& $enc $p.What)</div>") }
    $tail = ''
    if (Test-Path $script:LogFile) { $tail = (Get-Content $script:LogFile -Tail 40) -join "`n" }
    [void]$h.AppendLine("<h2>$(& $enc $T.log)</h2><pre>$(& $enc $tail)</pre></body></html>")
    $path = Join-Path $script:Dir ('TurboReport_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.html')
    if ($script:DryRun) { Say "  [DRY] would write $path" DarkYellow; return }
    [System.IO.File]::WriteAllText($path, $h.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Say "  [OK]  Report saved: $path" Green
    $script:OkCount++
    if (-not $script:AutoYes -and (Ask '  Open it in your browser?')) { Start-Process $path }
}

# ---------------------------------------------------------------- all in one
function Invoke-All {
    Say '[ ALL-IN-ONE ]' Cyan
    Say 'Order: restore point, clean, disk optimize, turbo, update, debloat (core list only).' Gray
    Say 'Startup items, services and Recycle Bin are not touched here. Everything is recorded for revert.' Gray
    Invoke-Clean -PreviewOnly
    if (-not (Ask 'Run the full optimization?')) { $script:PreScan = $null; return }
    Working-Begin 'Taking "before" measurements...'
    $before = Get-Metrics
    Working-End
    Write-Log 'ALL-IN-ONE started'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $okStart = $script:OkCount
    $probStart = $script:Problems.Count
    Show-Step 1 6 'Restore point'; Invoke-RestorePoint
    Show-Step 2 6 'Clean files';   Invoke-Clean -Auto
    Show-Step 3 6 'Disks';         Invoke-DiskOptimize -Auto
    Show-Step 4 6 'Turbo mode';    Invoke-Turbo
    Show-Step 5 6 'Updates';       Invoke-Update
    Show-Step 6 6 'Debloat';       Invoke-Debloat -Auto
    Working-Begin 'Taking "after" measurements...'
    $after = Get-Metrics
    Working-End
    $new = @($script:Problems | Select-Object -Skip $probStart)
    $warn = @($new | Where-Object { $_.Level -eq 'WARN' }).Count
    $err = @($new | Where-Object { $_.Level -eq 'ERROR' }).Count
    Write-Host ''
    Say ('  ' + (Format-Bar 6 6 24) + '  100%   DONE in ' + (Format-Duration $sw.Elapsed)) Green
    Write-Host '  ' -NoNewline
    Write-Host ('OK: {0}   ' -f ($script:OkCount - $okStart)) -NoNewline -ForegroundColor Green
    Write-Host ('Warnings: {0}   ' -f $warn) -NoNewline -ForegroundColor Yellow
    Write-Host ('Errors: {0}' -f $err) -ForegroundColor Red
    Write-Host ''
    Show-Compare $before $after
    Write-Log "ALL-IN-ONE completed in $(Format-Duration $sw.Elapsed): ok=$($script:OkCount - $okStart) warn=$warn err=$err"
}

# ---------------------------------------------------------------- menu
$script:AppName = 'WINDOWS TURBO OPTIMIZER'
$script:BoxW = 74
function Get-Glyph([string]$Name) {
    switch ($Name) {
        'tl' { return [string][char]0x256D }
        'tr' { return [string][char]0x256E }
        'bl' { return [string][char]0x2570 }
        'br' { return [string][char]0x256F }
        'h'  { return [string][char]0x2500 }
        'v'  { return [string][char]0x2502 }
        'dot' { return [string][char]0x25CF }
        'arrow' { return [string][char]0x203A }
    }
}
# The framed header with the tool name; shown at the top of every page.
function Show-Brand([string]$Page = '') {
    $w = $script:BoxW
    $v = Get-Glyph 'v'
    $modeText = 'LIVE'; $modeColor = 'Green'
    if ($script:DryRun) { $modeText = 'DRY RUN'; $modeColor = 'Yellow' }
    Write-Host ('  ' + (Get-Glyph 'tl') + ((Get-Glyph 'h') * $w) + (Get-Glyph 'tr')) -ForegroundColor DarkCyan
    $left = "  $($script:AppName)  v$($script:Version)"
    $right = "[ $modeText ]  "
    Write-Host ('  ' + $v) -NoNewline -ForegroundColor DarkCyan
    Write-Host $left -NoNewline -ForegroundColor White
    Write-Host (' ' * [math]::Max(1, $w - $left.Length - $right.Length)) -NoNewline
    Write-Host $right -NoNewline -ForegroundColor $modeColor
    Write-Host $v -ForegroundColor DarkCyan
    if ($Page) {
        $sub = '  ' + (Get-Glyph 'arrow') + ' ' + $Page
        Write-Host ('  ' + $v) -NoNewline -ForegroundColor DarkCyan
        Write-Host $sub -NoNewline -ForegroundColor Cyan
        Write-Host (' ' * [math]::Max(0, $w - $sub.Length)) -NoNewline
        Write-Host $v -ForegroundColor DarkCyan
    }
    Write-Host ('  ' + (Get-Glyph 'bl') + ((Get-Glyph 'h') * $w) + (Get-Glyph 'br')) -ForegroundColor DarkCyan
}
function Show-Page([string]$Title) {
    Clear-Host
    Show-Brand $Title
    Write-Host ''
}
function Show-Section([string]$Title) {
    $fill = [math]::Max(2, $script:BoxW - $Title.Length - 2)
    Write-Host ''
    Write-Host ('  ' + (Get-Glyph 'h') + (Get-Glyph 'h') + ' ') -NoNewline -ForegroundColor DarkCyan
    Write-Host $Title -NoNewline -ForegroundColor White
    Write-Host (' ' + ((Get-Glyph 'h') * $fill)) -ForegroundColor DarkCyan
}
function Write-MenuRow([string]$N1, [string]$T1, [string]$N2, [string]$T2) {
    Write-Host ('   {0,2}  ' -f $N1) -NoNewline -ForegroundColor Cyan
    if ($N2) {
        Write-Host ('{0,-33}' -f $T1) -NoNewline -ForegroundColor Gray
        Write-Host ('{0,2}  ' -f $N2) -NoNewline -ForegroundColor Cyan
        Write-Host $T2 -ForegroundColor Gray
    } else { Write-Host $T1 -ForegroundColor Gray }
}

# One table drives both the menu and the dispatch, grouped like the graphical versions.
$script:MenuDef = @(
    @{ G = 'QUICK START'; Items = @(
        @{ N = '1';  T = 'Doctor: find and fix problems'; P = 'Doctor';              A = { Invoke-Doctor } },
        @{ N = '2';  T = 'Diagnose (read-only)';          P = 'Diagnose';            A = { Invoke-Diagnose } },
        @{ N = '3';  T = 'ALL-IN-ONE optimization';       P = 'All-in-one';          A = { Invoke-All } },
        @{ N = '4';  T = 'HTML report';                   P = 'HTML report';         A = { Export-HtmlReport } }) },
    @{ G = 'CLEAN AND SPACE'; Items = @(
        @{ N = '5';  T = 'Clean files';                   P = 'Clean files';         A = { Invoke-Clean } },
        @{ N = '6';  T = 'Free up space';                 P = 'Free up space';       A = { Invoke-SpaceAnalyzer } },
        @{ N = '7';  T = 'Disk optimize / check';         P = 'Disks';               A = { Invoke-DiskOptimize } },
        @{ N = '8';  T = 'Debloat';                       P = 'Debloat';             A = { Invoke-Debloat } }) },
    @{ G = 'SPEED'; Items = @(
        @{ N = '9';  T = 'Turbo mode';                    P = 'Turbo mode';          A = { Invoke-Turbo } },
        @{ N = '10'; T = 'Startup programs';              P = 'Startup programs';    A = { Invoke-StartupManager } },
        @{ N = '11'; T = 'Optional services';             P = 'Services';            A = { Invoke-Services } }) },
    @{ G = 'UPDATE AND REPAIR'; Items = @(
        @{ N = '12'; T = 'Update apps (winget)';          P = 'Update apps';         A = { Invoke-Update } },
        @{ N = '13'; T = 'Repair system files';           P = 'Repair';              A = { Invoke-Repair } },
        @{ N = '14'; T = 'Drivers: backup / restore';     P = 'Drivers';             A = { Invoke-DriverMenu } }) },
    @{ G = 'NETWORK'; Items = @(
        @{ N = '15'; T = 'Fix Wi-Fi / Bluetooth hangs';   P = 'Wi-Fi and Bluetooth'; A = { Invoke-NetFixMenu } },
        @{ N = '16'; T = 'Network: DNS, hosts, Wi-Fi';    P = 'Network tools';       A = { Invoke-NetworkTools } }) },
    @{ G = 'SECURITY'; Items = @(
        @{ N = '17'; T = 'Security check';                P = 'Security check';      A = { Invoke-Doctor -Only @('Scan-Security') -Title 'Security check' } },
        @{ N = '18'; T = 'Defender: off / on / update';   P = 'Defender';            A = { Invoke-DefenderMenu } }) },
    @{ G = 'SAFETY AND TOOLS'; Items = @(
        @{ N = '19'; T = 'Create restore point';          P = 'Restore point';       A = { Invoke-RestorePoint } },
        @{ N = '20'; T = 'Revert recorded changes';       P = 'Revert';              A = { Invoke-Revert } },
        @{ N = '21'; T = 'Automatic care (weekly / watch)'; P = 'Automation';          A = { Invoke-AutomationMenu } },
        @{ N = '22'; T = 'Uninstall Turbo Optimizer';     P = 'Uninstall';           A = { Invoke-Uninstall } }) },
    @{ G = 'DISK AND BOOT'; Items = @(
        @{ N = '23'; T = 'Disk and boot check (MBR/GPT/UEFI)'; P = 'Disk and boot';      A = { Invoke-BootCheck } },
        @{ N = '24'; T = 'Switch to AHCI (prepare Windows)'; P = 'AHCI';                A = { Invoke-PrepareAhci } },
        @{ N = '25'; T = 'Convert MBR to GPT (advanced)'; P = 'MBR to GPT';          A = { Invoke-ConvertGpt } },
        @{ N = '26'; T = 'BIOS settings from Windows';    P = 'BIOS settings';       A = { Invoke-BiosSettings } },
        @{ N = '27'; T = 'Restart into BIOS settings';    P = 'BIOS settings';       A = { Invoke-FirmwareReboot } }) }
)
function Show-About {
    Say '  About Turbo Optimizer' White
    Say ''
    Say "  Version    $($script:Version)" Gray
    Say '  What       Free Windows 10/11 optimizer, cleaner and repair tool.' Gray
    Say '  Made by    Ebnhussein  (https://github.com/Ebnhussein)' Gray
    Say '  Project    https://github.com/Ebnhussein/TurboOpt' Cyan
    Say '  Privacy    No telemetry. It only goes online when you ask: updates, downloads, DNS tests.' Gray
    Say '  License    MIT. Free and open source.' Gray
    Say ''
}
function Show-Menu {
    Clear-Host
    Show-Brand
    $kind = 'desktop'
    if ($script:Plat.VM) { $kind = 'virtual machine' } elseif ($script:Plat.Laptop) { $kind = 'laptop' }
    Write-Host ''
    Say "  PC    $($script:Plat.Vendor) $($script:Plat.Model)  |  $($script:Plat.Caption) (build $($script:Plat.Build))  |  $kind" Gray
    foreach ($nt in @($script:Plat.Notes)) { Say "  Note  $nt" Yellow }
    Say "  CPU   $($script:Sys.CPU)  |  RAM: $($script:Sys.RAM) GB" DarkGray
    Say ('  GPU   ' + (@($script:Sys.GPU) -join '  |  ')) DarkGray
    foreach ($d in $script:Sys.Disks) { Say "  Disk  $d" DarkGray }
    if (Test-Path $script:HealthFile) {
        try {
            $hh = Get-Content $script:HealthFile -Raw | ConvertFrom-Json
            $hc = 'DarkGray'
            if ($hh.High -gt 0) { $hc = 'Red' } elseif ($hh.Med -gt 0) { $hc = 'Yellow' }
            Say ('  Last health check {0}: {1} serious, {2} medium, {3} info  (option 1)' -f ([datetime]$hh.Time).ToString('MM-dd HH:mm'), $hh.High, $hh.Med, $hh.Info) $hc
        } catch {}
    }
    foreach ($g in $script:MenuDef) {
        Show-Section $g.G
        $its = @($g.Items)
        for ($i = 0; $i -lt $its.Count; $i += 2) {
            if ($i + 1 -lt $its.Count) { Write-MenuRow $its[$i].N $its[$i].T $its[$i + 1].N $its[$i + 1].T }
            else { Write-MenuRow $its[$i].N $its[$i].T '' '' }
        }
    }
    Write-Host ''
    Write-Host ('  ' + ((Get-Glyph 'h') * ($script:BoxW + 2))) -ForegroundColor DarkCyan
    Write-Host '  ' -NoNewline
    $dryTxt = 'Dry run: OFF'
    if ($script:DryRun) { $dryTxt = 'Dry run: ON' }
    $hasUi = Test-Path (Join-Path $script:Dir 'TurboOptimizerWeb.ps1')
    $keys = @(@('D', $dryTxt), @('L', 'Log'), @('R', 'Problems'), @('C', 'Config'), @('A', 'About'))
    if ($hasUi) { $keys += , @('U', 'Open in browser') }
    $keys += , @('0', 'Exit')
    foreach ($k in $keys) {
        Write-Host ('[{0}]' -f $k[0]) -NoNewline -ForegroundColor Cyan
        Write-Host (' {0}   ' -f $k[1]) -NoNewline -ForegroundColor Gray
    }
    Write-Host ''
}
# Opens the browser version in its own process.
function Start-Ui([string]$Kind) {
    $path = Join-Path $script:Dir 'TurboOptimizerWeb.ps1'
    if (-not (Test-Path $path)) { Say "  Missing file: $path" Red; return $false }
    Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $path))
    return $true
}
# First screen: browser (default) or stay in the console. Returns 'console' or 'web'.
function Show-Launcher {
    Show-Page 'Start'
    if (-not (Test-Path (Join-Path $script:Dir 'TurboOptimizerWeb.ps1'))) { return 'console' }
    Say '  How do you want to work?' White
    Write-Host ''
    Write-Host '    1  ' -NoNewline -ForegroundColor Cyan; Write-Host 'Browser   ' -NoNewline -ForegroundColor White
    Write-Host 'a modern app window with 10 languages (recommended)' -ForegroundColor DarkGray
    Write-Host '    2  ' -NoNewline -ForegroundColor Cyan; Write-Host 'Console   ' -NoNewline -ForegroundColor White
    Write-Host 'numbered menu, stay in this window' -ForegroundColor DarkGray
    Write-Host ''
    $c = (Read-Host '  Select [1-2, Enter = 1]').Trim()
    if ($c -eq '2') { return 'console' }
    return 'web'
}

function Start-SelfTest {
    $script:DryRun = $true
    $script:AutoYes = $true
    Write-Log 'Self-test started'
    $script:Plat = Get-Platform
    Say ("SELFTEST platform: {0} {1} | {2} build {3} | laptop={4} vm={5} | notes: {6}" -f $script:Plat.Vendor, $script:Plat.Model, $script:Plat.Caption, $script:Plat.Build, $script:Plat.Laptop, $script:Plat.VM, (@($script:Plat.Notes) -join '; ')) Gray
    $steps = @(
        @{ N = 'config';       A = { $script:Cfg.Keys.Count } },
        @{ N = 'sysinfo';      A = { $null = Get-SysInfo } },
        @{ N = 'diagnose';     A = { Invoke-Diagnose } },
        @{ N = 'restore';      A = { Invoke-RestorePoint } },
        @{ N = 'clean';        A = { Invoke-Clean } },
        @{ N = 'startup';      A = { Invoke-StartupManager } },
        @{ N = 'services';     A = { Invoke-Services } },
        @{ N = 'turbo';        A = { Invoke-Turbo } },
        @{ N = 'disks';        A = { Invoke-DiskOptimize } },
        @{ N = 'update';       A = { Invoke-Update } },
        @{ N = 'repair';       A = { Invoke-Repair } },
        @{ N = 'debloat';      A = { Invoke-Debloat -Auto } },
        @{ N = 'netfix';       A = { Invoke-NetFixMenu } },
        @{ N = 'doctor';       A = { Invoke-Doctor } },
        @{ N = 'defender';     A = { Invoke-DefenderMenu } },
        @{ N = 'space';        A = { Invoke-SpaceAnalyzer } },
        @{ N = 'security';     A = { Invoke-Doctor -Only @('Scan-Security') -Title 'Security check' } },
        @{ N = 'drivers';      A = { Invoke-DriverMenu } },
        @{ N = 'network';      A = { Invoke-NetworkTools } },
        @{ N = 'report';       A = { Export-HtmlReport } },
        @{ N = 'revert';       A = { Invoke-Revert } },
        @{ N = 'bootcheck';    A = { Invoke-BootCheck } },
        @{ N = 'ahci';         A = { Invoke-PrepareAhci } },
        @{ N = 'gpt';          A = { Invoke-ConvertGpt } },
        @{ N = 'bios';         A = { Invoke-BiosSettings } },
        @{ N = 'firmware';     A = { Invoke-FirmwareReboot } }
    )
    $failed = 0
    foreach ($s in $steps) {
        try { & $s.A; Say "SELFTEST PASS: $($s.N)" Green }
        catch { $failed++; Say "SELFTEST FAIL: $($s.N) : $($_.Exception.Message)" Red; Write-Log "Self-test FAIL $($s.N): $($_.Exception.Message)" }
    }
    Show-Problems
    Write-Log "Self-test finished, failures: $failed"
    exit $failed
}

# ---------------------------------------------------------------- main
if ($AsLibrary) { return }     # the graphical version only needs the functions above
if ($SelfTest) { Start-SelfTest }

Write-Log '==============================================='
Write-Log "Script started (v$($script:Version)) DryRun=$($script:DryRun)"
Write-ErrHeader
if ($Doctor) {
    # Used by the scheduled background check: scan, write the report, exit.
    $script:Plat = Get-Platform
    Invoke-Doctor -ScanOnly:$ScanOnly
    exit 0
}
if ($Monitor) { Invoke-MonitorRun; exit 0 }
if ($Maintain) {
    # Weekly safe maintenance: clean temp files and caches that are not in use, then scan. Never asks, never closes anything.
    $script:Unattended = $true
    $script:Plat = Get-Platform
    Write-Log 'Weekly maintenance started'
    Invoke-Clean -Auto
    Invoke-Doctor -ScanOnly
    Write-Log 'Weekly maintenance finished'
    exit 0
}
if ($Browser) { if (Start-Ui 'web') { exit 0 } }     # started by the installer: open the browser right away
try { $script:Sys = Get-SysInfo }
catch {
    Add-ErrorRecord 'Read system information' $_
    $script:Sys = [pscustomobject]@{ CPU = 'unknown'; RAM = '?'; GPU = @(); Disks = @() }
}
try { $script:Plat = Get-Platform }
catch {
    Add-ErrorRecord 'Read platform information' $_
    $script:Plat = [pscustomobject]@{ Vendor = 'unknown'; Model = ''; Build = 19045; Caption = 'Windows'; IsWin11 = $false; Laptop = $false; HasBattery = $false; VM = $false; Notes = @() }
}
if ($script:Plat.Build -lt 17763) {
    Say "`n  This Windows version ($($script:Plat.Caption), build $($script:Plat.Build)) is too old. The tool needs Windows 10 version 1809 or newer." Red
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if (-not $Console -and -not $script:AutoYes) {
    $mode = Show-Launcher
    if ($mode -ne 'console') {
        if (Start-Ui $mode) { exit 0 }
    }
}

while ($true) {
    try {
    Show-Menu
    Write-Host ''
    Write-Host '  ' -NoNewline
    $choice = (Read-Host ((Get-Glyph 'arrow') + ' Select')).Trim().ToUpper()
    $item = $null
    foreach ($g in $script:MenuDef) { foreach ($it in $g.Items) { if ($it.N -eq $choice) { $item = $it } } }
    if ($item) { Show-Page $item.P; & $item.A; if ($script:UninstallDone) { Start-Sleep -Seconds 2; exit 0 }; Pause-Menu; continue }
    switch ($choice) {
        'D'  { $script:DryRun = -not $script:DryRun; Write-Log "DryRun set to $($script:DryRun)" }
        'L'  { if (Test-Path $script:LogFile) { Start-Process notepad $script:LogFile } }
        'R'  { if (Test-Path $script:ErrFile) { Start-Process notepad $script:ErrFile } else { Say 'No problems have been recorded yet.' Green; Start-Sleep -Seconds 2 } }
        'C'  { Start-Process notepad $script:ConfigFile; Read-Host 'Save the config, then press Enter to reload' | Out-Null; $script:Cfg = Read-Config }
        'A'  { Show-Page 'About'; Show-About; Pause-Menu }
        'U'  {
            $m = Show-Launcher
            if ($m -ne 'console') { if (Start-Ui $m) { Write-Log 'Script exited (opened the UI)'; exit 0 } }
        }
        '0'  { Write-Log 'Script exited'; exit 0 }
    }
    } catch {
        Say "`n  [x] Unexpected error: $($_.Exception.Message)" Red
        Add-ErrorRecord "Menu choice '$choice'" $_
        Pause-Menu
    }
}
