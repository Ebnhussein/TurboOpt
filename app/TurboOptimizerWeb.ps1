<#
  Turbo Optimizer - browser version.
  A tiny web server that listens on 127.0.0.1 only (random port, secret token) and shows TurboWeb.html in an Edge/Chrome app window.
  The page can only ask for actions by name; it never sends commands. Same engine as TurboOptimizer.ps1.
  Run through TurboOptimizerWeb.bat.   -Test / -TestAll = start, drive the pages' own API in dry-run, report, exit.
#>
[CmdletBinding()]
param([switch]$Test, [switch]$TestAll, [switch]$NoBrowser)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$corePath = Join-Path $here 'TurboOptimizer.ps1'
$stringsPath = Join-Path $here 'TurboUI_strings.json'
$EmbeddedStrings = ''   # base64, filled in by tools/build-release.ps1 for the user package
$EmbeddedHtml = ''      # base64, filled in by tools/build-release.ps1 for the user package
function Get-Embedded([string]$B64, [string]$Path) {
    if ($B64) { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64)) }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}
$htmlPath = Join-Path $here 'TurboWeb.html'
$prefPath = Join-Path $here 'turbo_ui.json'
$errFile = Join-Path $here 'turbo_ui_errors.log'
function Write-UiError([string]$Where, $Err) {
    try { Add-Content -Path $errFile -Value ("[{0}] {1}: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Where, $Err.Exception.Message) } catch {}
}
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $Test -and -not $NoBrowser -and -not (Test-Admin)) {   # -NoBrowser = developer preview: prints the address, no elevation
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit
}
if (-not (Test-Path $corePath)) { Write-Output "Missing file: $corePath"; exit 1 }
if (-not $EmbeddedStrings -and -not (Test-Path $stringsPath)) { Write-Output "Missing file: $stringsPath"; exit 1 }
if (-not $EmbeddedHtml -and -not (Test-Path $htmlPath)) { Write-Output "Missing file: $htmlPath"; exit 1 }

# ---------------------------------------------------------------- languages
$S = (Get-Embedded $EmbeddedStrings $stringsPath) | ConvertFrom-Json
$script:Lang = 'en'
if (Test-Path $prefPath) { try { $p = Get-Content $prefPath -Raw | ConvertFrom-Json; if ($p.Lang -and $S.PSObject.Properties[$p.Lang]) { $script:Lang = [string]$p.Lang } } catch {} }

# ---------------------------------------------------------------- engine (the same engine as the console)
$sync = [hashtable]::Synchronized(@{})
$sync.Q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Evt = New-Object System.Threading.ManualResetEventSlim($false)
$sync.Answer = $null
$sync.Core = $corePath
$sync.Ids = @()
$sync.Keys = @()
$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.ThreadOptions = 'ReuseThread'
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$bootstrap = @'
. $sync.Core -AsLibrary
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline, $Separator = ' ')
    $text = ''
    if ($null -ne $Object) { $text = (@($Object) | ForEach-Object { "$_" }) -join $Separator }
    $sync.Q.Enqueue(@{ K = 'text'; T = $text; C = [string]$ForegroundColor; N = [bool]$NoNewline })
}
function Ask {
    param([string]$Question)
    $sync.Evt.Reset(); $sync.Answer = $null
    $sync.Q.Enqueue(@{ K = 'ask'; T = $Question })
    $sync.Evt.Wait()
    return ($sync.Answer -eq $true)
}
function Read-Host {
    param([string]$Prompt)
    $sync.Evt.Reset(); $sync.Answer = $null
    $sync.Q.Enqueue(@{ K = 'input'; T = $Prompt })
    $sync.Evt.Wait()
    return [string]$sync.Answer
}
function Pause-Menu { }
function Clear-Host { }
function Working-Begin { param([string]$Text) $sync.Q.Enqueue(@{ K = 'work'; T = $Text }) }
function Working-End { $sync.Q.Enqueue(@{ K = 'work'; T = '' }) }
function Show-Step { param([int]$Index, [int]$Total, [string]$Title) $sync.Q.Enqueue(@{ K = 'step'; I = $Index; N = $Total; T = $Title }) }
function Publish-Done { $sync.Q.Enqueue(@{ K = 'done' }) }
function Publish-Findings {
    $items = @()
    foreach ($f in $script:Findings) { $items += @{ Id = [string]$f.Id; Sev = [string]$f.Sev; Title = [string]$f.Title; Detail = [string]$f.Detail; Fix = [string]$f.Fix; Download = [string]$f.Download } }
    $sync.Q.Enqueue(@{ K = 'findings'; Items = $items })
}
function Publish-Startup {
    $items = @()
    foreach ($it in @(Get-StartupItems)) { $items += @{ Key = "$($it.Kind)|$($it.Location)|$($it.Name)"; Name = [string]$it.Name; Command = [string]$it.Command; Protected = [bool](Test-Protected $it.Name) } }
    $sync.Q.Enqueue(@{ K = 'startup'; Items = $items })
}
function Publish-Programs {
    $items = @()
    foreach ($p in @(Get-InstalledPrograms)) { $items += @{ Key = [string]$p.Key; Name = [string]$p.Name; Version = [string]$p.Version; Publisher = [string]$p.Publisher; SizeMB = [int]$p.SizeMB; Store = ($p.Kind -eq 'Store'); Protected = [bool](Test-ProgramProtected $p) } }
    $sync.Q.Enqueue(@{ K = 'programs'; Items = $items })
}
$script:Plat = $null
'@
$monBootstrap = @'
. $sync.Core -AsLibrary
function Publish-Monitor { $sync.Mon = Get-MonitorSample }
'@
$infoBootstrap = @'
. $sync.Core -AsLibrary
function Publish-Info {
    if (-not $script:Sys) { $script:Sys = Get-SysInfo }
    if (-not $script:Plat) { $script:Plat = Get-Platform }
    $os = Get-CimInstance Win32_OperatingSystem
    $free = [math]::Round((Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 2)
    $ram = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)
    $startup = @(Get-StartupItems).Count
    $health = $null
    if (Test-Path $script:HealthFile) { try { $health = Get-Content $script:HealthFile -Raw | ConvertFrom-Json } catch {} }
    $sync.Q.Enqueue(@{
        K = 'info'; Vendor = $script:Plat.Vendor; Model = $script:Plat.Model; Caption = $script:Plat.Caption; Build = $script:Plat.Build
        Laptop = $script:Plat.Laptop; VM = $script:Plat.VM; FreeGB = $free; RamPct = $ram; Startup = $startup
        High = $(if ($health) { [int]$health.High } else { -1 }); Med = $(if ($health) { [int]$health.Med } else { 0 })
    })
}
'@
$boot = [powershell]::Create()
$boot.Runspace = $rs
[void]$boot.AddScript($bootstrap)
$bootErr = $null
try { [void]$boot.Invoke() } catch { $bootErr = $_.Exception.Message }
if ($boot.Streams.Error.Count -gt 0) { $bootErr = ($boot.Streams.Error | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join "`n" }
$boot.Dispose()
if ($bootErr) { Write-Output "The engine could not start: $bootErr"; exit 1 }
$infoRs = [runspacefactory]::CreateRunspace()
$infoRs.ApartmentState = 'STA'
$infoRs.ThreadOptions = 'ReuseThread'
$infoRs.Open()
$infoRs.SessionStateProxy.SetVariable('sync', $sync)
$ib = [powershell]::Create()
$ib.Runspace = $infoRs
[void]$ib.AddScript($infoBootstrap)
try { [void]$ib.Invoke() } catch {}
$ib.Dispose()

$monRs = $null
function Start-MonitorRefresh {
    if ($script:MonAsync -and -not $script:MonAsync.IsCompleted) { return }
    if ($script:MonPs) { try { $script:MonPs.Dispose() } catch {}; $script:MonPs = $null }
    if (-not $script:MonRsReady) {
        $script:MonRsReady = $true
        $script:MonRs = [runspacefactory]::CreateRunspace()
        $script:MonRs.ApartmentState = 'STA'
        $script:MonRs.ThreadOptions = 'ReuseThread'
        $script:MonRs.Open()
        $script:MonRs.SessionStateProxy.SetVariable('sync', $sync)
        $mb = [powershell]::Create(); $mb.Runspace = $script:MonRs
        [void]$mb.AddScript($monBootstrap)
        try { [void]$mb.Invoke() } catch {}
        $mb.Dispose()
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:MonRs
    [void]$ps.AddScript('try { Publish-Monitor } catch { }')
    $script:MonPs = $ps
    $script:MonAsync = $ps.BeginInvoke()
}

# ---------------------------------------------------------------- what the page may ask for (by name only)
$Categories = @(
    @{ Id = 'home'; K = 'cat_home'; Actions = @(
        @{ K = 'act_doctor'; D = 'd_doctor'; Cmd = 'Invoke-Doctor -ScanOnly; Publish-Findings' },
        @{ K = 'act_diag'; D = 'd_diag'; Cmd = 'Invoke-Diagnose' },
        @{ K = 'act_all'; D = 'd_all'; Cmd = 'Invoke-All' },
        @{ K = 'act_report'; D = 'd_report'; Cmd = "Export-HtmlReport -Lang '{LANG}'" }) },
    @{ Id = 'clean'; K = 'cat_clean'; Actions = @(
        @{ K = 'act_clean'; D = 'd_clean'; Cmd = 'Invoke-Clean' },
        @{ K = 'act_space'; D = 'd_space'; Cmd = 'Invoke-SpaceAnalyzer' },
        @{ K = 'act_disks'; D = 'd_disks'; Cmd = 'Invoke-DiskOptimize' },
        @{ K = 'act_debloat'; D = 'd_debloat'; Cmd = 'Invoke-Debloat' },
        @{ K = 'act_programs'; D = 'd_programs'; Cmd = 'Publish-Programs' }) },
    @{ Id = 'monitor'; K = 'cat_monitor'; Actions = @() },
    @{ Id = 'speed'; K = 'cat_speed'; Actions = @(
        @{ K = 'act_turbo'; D = 'd_turbo'; Cmd = 'Invoke-Turbo' },
        @{ K = 'act_startup'; D = 'd_startup'; Cmd = 'Publish-Startup' },
        @{ K = 'act_services'; D = 'd_services'; Cmd = 'Invoke-Services' }) },
    @{ Id = 'update'; K = 'cat_update'; Actions = @(
        @{ K = 'act_update'; D = 'd_update'; Cmd = 'Invoke-Update' },
        @{ K = 'act_repair'; D = 'd_repair'; Cmd = 'Invoke-Repair' },
        @{ K = 'act_drv_backup'; D = 'd_drv_backup'; Cmd = 'Invoke-DriverBackup' },
        @{ K = 'act_drv_restore'; D = 'd_drv_restore'; Cmd = 'Invoke-DriverRestore' }) },
    @{ Id = 'network'; K = 'cat_network'; Actions = @(
        @{ K = 'act_wifi_reset'; D = 'd_wifi_reset'; Cmd = 'Invoke-WifiReset' },
        @{ K = 'act_bt_reset'; D = 'd_bt_reset'; Cmd = 'Invoke-BluetoothReset' },
        @{ K = 'act_power'; D = 'd_power'; Cmd = 'Invoke-PowerSavingFix' },
        @{ K = 'act_bt_nosound'; D = 'd_bt_nosound'; Cmd = 'Invoke-BluetoothNoSoundFix' },
        @{ K = 'act_wifi_profiles'; D = 'd_wifi_profiles'; Cmd = 'Invoke-WifiProfiles' },
        @{ K = 'act_dns_test'; D = 'd_dns_test'; Cmd = 'Invoke-DnsBenchmark' },
        @{ K = 'act_dns_switch'; D = 'd_dns_switch'; Special = 'dns' },
        @{ K = 'act_hosts'; D = 'd_hosts'; Cmd = 'Invoke-HostsCheck' },
        @{ K = 'act_wifi_channels'; D = 'd_wifi_channels'; Cmd = 'Invoke-WifiChannels' },
        @{ K = 'act_net_deep'; D = 'd_net_deep'; Cmd = 'Invoke-NetDeepReset' }) },
    @{ Id = 'security'; K = 'cat_security'; Actions = @(
        @{ K = 'act_sec_check'; D = 'd_sec_check'; Cmd = "Invoke-Doctor -ScanOnly -Only @('Scan-Security') -Title 'Security check'; Publish-Findings" },
        @{ K = 'act_def_status'; D = 'd_def_status'; Cmd = 'Show-DefenderStatus' },
        @{ K = 'act_def_off'; D = 'd_def_off'; Cmd = 'Invoke-DefenderDisable' },
        @{ K = 'act_def_on'; D = 'd_def_on'; Cmd = 'Invoke-DefenderEnable' },
        @{ K = 'act_def_update'; D = 'd_def_update'; Cmd = 'Invoke-DefenderUpdate' }) },
    @{ Id = 'disk'; K = 'cat_disk'; Actions = @(
        @{ K = 'act_boot'; D = 'd_boot'; Cmd = 'Invoke-BootCheck; Publish-Findings' },
        @{ K = 'act_ahci'; D = 'd_ahci'; Cmd = 'Invoke-PrepareAhci' },
        @{ K = 'act_gpt'; D = 'd_gpt'; Cmd = 'Invoke-ConvertGpt' },
        @{ K = 'act_bios'; D = 'd_bios'; Cmd = 'Invoke-BiosSettings' },
        @{ K = 'act_fw'; D = 'd_fw'; Cmd = 'Invoke-FirmwareReboot' },
        @{ K = 'act_guide'; D = 'd_guide'; Cmd = 'Invoke-BiosGuide' },
        @{ K = 'act_order'; D = 'd_order'; Cmd = 'Invoke-BootOrder' },
        @{ K = 'act_dump'; D = 'd_dump'; Cmd = 'Invoke-BiosDump' }) },
    @{ Id = 'safety'; K = 'cat_safety'; Actions = @(
        @{ K = 'act_restore'; D = 'd_restore'; Cmd = 'Invoke-RestorePoint' },
        @{ K = 'act_revert'; D = 'd_revert'; Cmd = 'Invoke-Revert' },
        @{ K = 'act_auto'; D = 'd_auto'; Special = 'auto' },
        @{ K = 'act_uninstall'; D = 'd_uninstall'; Cmd = 'Invoke-Uninstall' },
        @{ K = 'act_open_log'; D = 'd_open_log'; Special = 'open_log' },
        @{ K = 'act_open_problems'; D = 'd_open_problems'; Special = 'open_problems' },
        @{ K = 'act_open_config'; D = 'd_open_config'; Special = 'open_config' }) }
)
$ActionById = @{}
foreach ($c in $Categories) { foreach ($a in $c.Actions) { $ActionById[$a.K] = $a } }
if ($Test) { $ActionById['__hello'] = @{ K = '__hello'; Cmd = 'Say ''hello from the engine'' Green' } }
function Get-Text([string]$Key) {
    $l = $S.PSObject.Properties[$script:Lang]
    if ($l -and $l.Value.PSObject.Properties[$Key]) { return [string]$l.Value.$Key }
    return [string]$S.en.$Key
}

# ---------------------------------------------------------------- state shared with the page
$script:Ev = New-Object System.Collections.ArrayList
$script:EvBase = 0
$script:IdSeq = 0
$script:Prompt = $null
$script:Dialog = $null
$script:LastInfo = $null
$script:Busy = $false
$script:Pending = $null
$script:CurPs = $null
$script:CurAsync = $null
$script:InfoPs = $null
$script:InfoAsync = $null
$script:ActionStart = Get-Date
$script:WorkText = ''
$script:Step = $null
$script:Quit = $false
$script:ByeAt = $null
$script:Browser = $null
$script:LastSeen = Get-Date

function Add-Event($e) {
    [void]$script:Ev.Add($e)
    if ($script:Ev.Count -gt 20000) { $script:Ev.RemoveRange(0, 5000); $script:EvBase += 5000 }
}
function Start-InfoRefresh {
    if ($script:InfoAsync -and -not $script:InfoAsync.IsCompleted) { return }
    if ($script:InfoPs) { try { $script:InfoPs.Dispose() } catch {}; $script:InfoPs = $null }
    $ps = [powershell]::Create()
    $ps.Runspace = $infoRs
    [void]$ps.AddScript('try { Publish-Info } catch { }')
    $script:InfoPs = $ps
    $script:InfoAsync = $ps.BeginInvoke()
}
function Start-Action([string]$Cmd, [string]$Title, [bool]$Dry) {
    $script:Busy = $true
    $script:ActionStart = Get-Date
    $script:WorkText = ''
    $script:Step = $null
    Add-Event @{ k = 'head'; t = $Title }
    $d = '$false'
    if ($Dry) { $d = '$true' }
    $Cmd = $Cmd.Replace('{LANG}', $(if ($script:Lang -eq 'ar') { 'ar' } else { 'en' }))
    $code = @"
`$script:DryRun = $d
try { $Cmd } catch { Add-ErrorRecord 'UI action' `$_; Write-Host ('Error: ' + `$_.Exception.Message) -ForegroundColor Red }
Show-Problems
Publish-Done
"@
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($code)
    $script:CurPs = $ps
    $script:CurAsync = $ps.BeginInvoke()
}
function Receive-Message($m) {
    switch ($m.K) {
        'text' { Add-Event @{ k = 'text'; t = [string]$m.T; c = [string]$m.C; n = [bool]$m.N } }
        'ask' { $script:IdSeq++; $script:Prompt = @{ id = $script:IdSeq; k = 'ask'; t = [string]$m.T } }
        'input' {
            $p = [string]$m.T
            $mode = 'text'; $def = ''
            if ($p -match 'A = all safe ones') { $mode = 'all' }
            elseif ($p -match '\[(\d+)\]\s*:?\s*$') { $def = $Matches[1] }
            $script:IdSeq++; $script:Prompt = @{ id = $script:IdSeq; k = 'input'; t = $p; mode = $mode; def = $def }
        }
        'work' { $script:WorkText = [string]$m.T }
        'step' { $script:Step = @{ i = [int]$m.I; n = [int]$m.N }; $script:WorkText = ('{0}/{1}  {2}' -f $m.I, $m.N, $m.T) }
        'findings' { $script:IdSeq++; $script:Dialog = @{ id = $script:IdSeq; k = 'findings'; items = @($m.Items) } }
        'startup' { $script:IdSeq++; $script:Dialog = @{ id = $script:IdSeq; k = 'startup'; items = @($m.Items) } }
        'programs' { $script:IdSeq++; $script:Dialog = @{ id = $script:IdSeq; k = 'programs'; items = @($m.Items) } }
        'info' { $script:LastInfo = $m }
        'done' {
            $script:Busy = $false
            $script:Step = $null
            Add-Event @{ k = 'done'; secs = [int]((Get-Date) - $script:ActionStart).TotalSeconds }
            Start-InfoRefresh
            if ($script:Pending) { $p = $script:Pending; $script:Pending = $null; Start-Action $p.Cmd $p.Title $p.Dry }
        }
    }
}
function Update-Engine {
    $m = $null; $n = 0
    while ($n -lt 500 -and $sync.Q.TryDequeue([ref]$m)) { $n++; try { Receive-Message $m } catch { Write-UiError "message $($m.K)" $_ } }
    if ($script:InfoAsync -and $script:InfoAsync.IsCompleted -and $script:InfoPs) {
        try { $script:InfoPs.EndInvoke($script:InfoAsync) | Out-Null } catch {}
        $script:InfoPs.Dispose(); $script:InfoPs = $null; $script:InfoAsync = $null
    }
    if ($script:Busy -and $script:CurAsync -and $script:CurAsync.IsCompleted -and $sync.Q.IsEmpty) {
        foreach ($e in @($script:CurPs.Streams.Error | Select-Object -First 3)) { Add-Event @{ k = 'text'; t = ('Error: ' + $e.ToString()); c = 'Red'; n = $false } }
        $script:CurPs.Dispose(); $script:CurPs = $null; $script:CurAsync = $null
        Receive-Message @{ K = 'done' }
    } elseif ($script:CurAsync -and $script:CurAsync.IsCompleted -and $script:CurPs) {
        try { $script:CurPs.EndInvoke($script:CurAsync) | Out-Null } catch {}
        $script:CurPs.Dispose(); $script:CurPs = $null; $script:CurAsync = $null
    }
}

# ---------------------------------------------------------------- the web server
$token = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
try {
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 24; $rng.GetBytes($bytes); $rng.Dispose()
    $token = ([BitConverter]::ToString($bytes) -replace '-', '').ToLower()
} catch {}
$listener = $null
$port = 0
for ($i = 0; $i -lt 40 -and -not $listener; $i++) {
    $try = Get-Random -Minimum 20000 -Maximum 60000
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$try/")
    try { $l.Start(); $listener = $l; $port = $try } catch { try { $l.Close() } catch {} }
}
if (-not $listener) { Write-Output 'Could not open a local port.'; exit 1 }
$origin = "http://127.0.0.1:$port"
$hostHdr = "127.0.0.1:$port"
$utf8 = New-Object System.Text.UTF8Encoding($false)

$catsOut = @()
foreach ($c in $Categories) {
    $acts = @()
    foreach ($a in $c.Actions) { $acts += @{ k = $a.K; d = $a.D; special = [string]$a.Special } }
    $catsOut += @{ id = $c.Id; k = $c.K; actions = $acts }
}
$htmlTemplate = Get-Embedded $EmbeddedHtml $htmlPath
$appVersion = ''
try { $vm = [regex]::Match([System.IO.File]::ReadAllText($corePath), '(?m)^\$script:Version\s*=\s*''([^'']+)'''); if ($vm.Success) { $appVersion = $vm.Groups[1].Value } } catch {}
function Get-Page {
    $boot = ConvertTo-Json -InputObject @{ token = $token; lang = $script:Lang; S = $S; cats = $catsOut; version = $appVersion } -Depth 8 -Compress
    $boot = $boot.Replace('<', '<').Replace('>', '>').Replace('&', '&')
    return $htmlTemplate.Replace('__BOOT__', $boot)
}
function Send-Bytes($ctx, [byte[]]$data, [string]$type, [int]$code = 200) {
    $r = $ctx.Response
    $r.StatusCode = $code
    $r.ContentType = $type
    $r.Headers.Add('Cache-Control', 'no-store')
    $r.Headers.Add('X-Content-Type-Options', 'nosniff')
    $r.Headers.Add('Content-Security-Policy', "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
    $r.ContentLength64 = $data.Length
    $r.OutputStream.Write($data, 0, $data.Length)
    $r.OutputStream.Close()
}
function Send-Json($ctx, $obj, [int]$code = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    Send-Bytes $ctx $utf8.GetBytes($json) 'application/json; charset=utf-8' $code
}
function Read-Body($ctx) {
    $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, $utf8)
    $t = $sr.ReadToEnd()
    if (-not $t) { return $null }
    return ($t | ConvertFrom-Json)
}
function Open-File([string]$Name) {
    $f = Join-Path $here $Name
    if (Test-Path $f) { Start-Process notepad $f; return $true }
    return $false
}
function Handle-Request($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    if ($req.Headers['Host'] -cne $hostHdr) { Send-Json $ctx @{ error = 'host' } 403; return }
    $script:LastSeen = Get-Date
    if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
        if ($req.QueryString['t'] -cne $token) { Send-Json $ctx @{ error = 'token' } 403; return }
        $script:ByeAt = $null
        Send-Bytes $ctx $utf8.GetBytes((Get-Page)) 'text/html; charset=utf-8'
        return
    }
    if (-not $path.StartsWith('/api/')) { Send-Json $ctx @{ error = 'not found' } 404; return }
    if ($req.Headers['X-Token'] -cne $token) { Send-Json $ctx @{ error = 'token' } 403; return }
    if ($req.HttpMethod -eq 'POST') {
        $o = $req.Headers['Origin']
        if ($o -and $o -cne $origin) { Send-Json $ctx @{ error = 'origin' } 403; return }
        if (-not ([string]$req.ContentType).StartsWith('application/json')) { Send-Json $ctx @{ error = 'type' } 415; return }
    }
    if ($path -ne '/api/bye') { $script:ByeAt = $null }
    Update-Engine
    $body = $null
    if ($req.HttpMethod -eq 'POST') { try { $body = Read-Body $ctx } catch { Send-Json $ctx @{ error = 'json' } 400; return } }
    switch ($path) {
        '/api/poll' {
            $since = 0
            [void][int]::TryParse([string]$req.QueryString['since'], [ref]$since)
            $from = [math]::Max($since, $script:EvBase) - $script:EvBase
            $evs = @()
            if ($from -lt $script:Ev.Count) { $evs = @($script:Ev.GetRange($from, $script:Ev.Count - $from).ToArray()) }
            $next = $script:EvBase + $script:Ev.Count
            $secs = 0
            if ($script:Busy) { $secs = [int]((Get-Date) - $script:ActionStart).TotalSeconds }
            Send-Json $ctx @{ events = $evs; next = $next; busy = $script:Busy; work = $script:WorkText; elapsed = $secs; step = $script:Step; prompt = $script:Prompt; dialog = $script:Dialog; info = $script:LastInfo }
        }
        '/api/run' {
            $a = $null
            if ($body -and $body.id) { $a = $ActionById[[string]$body.id] }
            if (-not $a) { Send-Json $ctx @{ error = 'unknown action' } 400; return }
            if ($script:Busy) { Send-Json $ctx @{ error = 'busy' } 409; return }
            if ($a.Special) {
                $ok = $true
                switch ($a.Special) {
                    'open_log' { $ok = Open-File 'turbo_log.txt' }
                    'open_problems' { $ok = Open-File 'turbo_errors.log'; if (-not $ok) { Add-Event @{ k = 'text'; t = (Get-Text 'msg_no_findings'); c = 'Green'; n = $false } } }
                    'open_config' { $ok = Open-File 'config.ini' }
                }
                Send-Json $ctx @{ ok = $true }
                return
            }
            $script:LastDry = ($body.dry -eq $true)
            Start-Action $a.Cmd (Get-Text $a.K) $script:LastDry
            Send-Json $ctx @{ ok = $true }
        }
        '/api/answer' {
            if ($script:Prompt -and $body -and [int]$body.id -eq $script:Prompt.id) {
                if ($script:Prompt.k -eq 'ask') { $sync.Answer = ($body.value -eq $true) } else { $sync.Answer = [string]$body.value }
                $script:Prompt = $null
                $sync.Evt.Set()
            }
            Send-Json $ctx @{ ok = $true }
        }
        '/api/dialog_close' {
            if ($script:Dialog -and $body -and [int]$body.id -eq $script:Dialog.id) { $script:Dialog = $null }
            Send-Json $ctx @{ ok = $true }
        }
        '/api/fix' {
            $mode = [string]$body.mode
            $ids = @(@($body.ids) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[\w\.\-:]{1,80}$' })
            if (($mode -ne 'Fix' -and $mode -ne 'Ignore') -or $ids.Count -eq 0) { Send-Json $ctx @{ error = 'bad request' } 400; return }
            $sync.Ids = $ids
            $cmd = "Invoke-DoctorFixSelected -Ids @(`$sync.Ids) -Mode '$mode'"
            if ($script:Busy) { $script:Pending = @{ Cmd = $cmd; Title = (Get-Text 'dlg_findings'); Dry = $script:LastDry } } else { Start-Action $cmd (Get-Text 'dlg_findings') $script:LastDry }
            Send-Json $ctx @{ ok = $true }
        }
        '/api/startup' {
            $mode = [string]$body.mode
            $keys = @(@($body.keys) | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Length -lt 600 })
            $mins = 2
            [void][int]::TryParse([string]$body.minutes, [ref]$mins)
            $mins = [math]::Max(1, [math]::Min(30, $mins))
            if (($mode -ne 'Disable' -and $mode -ne 'Delay') -or $keys.Count -eq 0) { Send-Json $ctx @{ error = 'bad request' } 400; return }
            $sync.Keys = $keys
            $cmd = "Invoke-StartupBatch -Mode '$mode' -Keys @(`$sync.Keys) -Minutes $mins"
            if ($script:Busy) { $script:Pending = @{ Cmd = $cmd; Title = (Get-Text 'dlg_startup'); Dry = $script:LastDry } } else { Start-Action $cmd (Get-Text 'dlg_startup') $script:LastDry }
            Send-Json $ctx @{ ok = $true }
        }
        '/api/monitor' {
            Start-MonitorRefresh
            Send-Json $ctx @{ m = $sync.Mon }
        }
        '/api/uninstall' {
            $keys = @(@($body.keys) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^(Win32\|(machine|machine32|user)\|[^|;"<>`$]{1,200}|Store\|[\w\.\-~]{1,200})$' })
            if ($keys.Count -eq 0 -or $keys.Count -gt 40) { Send-Json $ctx @{ error = 'bad request' } 400; return }
            $sync.Keys = $keys
            $cmd = "Invoke-DeepUninstall -Keys @(`$sync.Keys)"
            if ($script:Busy) { Send-Json $ctx @{ error = 'busy' } 409; return }
            Start-Action $cmd (Get-Text 'dlg_programs') $script:LastDry
            Send-Json $ctx @{ ok = $true }
        }
        '/api/dns' {
            $pick = -1
            [void][int]::TryParse([string]$body.pick, [ref]$pick)
            if ($pick -lt 0 -or $pick -gt 3) { Send-Json $ctx @{ error = 'bad request' } 400; return }
            if ($script:Busy) { Send-Json $ctx @{ error = 'busy' } 409; return }
            if ($pick -eq 3) { $cmd = "Set-DnsProvider @{ N = 'Automatic'; Auto = `$true }" } else { $cmd = "Set-DnsProvider `$script:DnsProviders[$pick]" }
            Start-Action $cmd (Get-Text 'act_dns_switch') $script:LastDry
            Send-Json $ctx @{ ok = $true }
        }
        '/api/stop' {
            if ($script:Busy -and $script:CurPs) {
                try { [void]$script:CurPs.BeginStop($null, $null) } catch {}
                $sync.Answer = $false; $script:Prompt = $null; $sync.Evt.Set()
                Add-Event @{ k = 'stopped' }
            }
            Send-Json $ctx @{ ok = $true }
        }
        '/api/auto' {
            $pf = Join-Path $here 'turbo_prefs.json'
            $prefs = @{}
            if (Test-Path $pf) { try { $o = Get-Content $pf -Raw | ConvertFrom-Json; foreach ($pp in $o.PSObject.Properties) { $prefs[$pp.Name] = $pp.Value } } catch {} }
            if ($req.HttpMethod -eq 'GET') {
                $mode = 'off'
                if (Get-ScheduledTask -TaskName 'TurboOptimizer Monitor' -ErrorAction SilentlyContinue) { $mode = 'monitor' }
                elseif (Get-ScheduledTask -TaskName 'TurboOptimizer Weekly Maintenance' -ErrorAction SilentlyContinue) { $mode = 'weekly' }
                Send-Json $ctx @{ mode = $mode; asked = [bool]$prefs['Asked'] }
                return
            }
            $m = [string]$body.mode
            if ($m -eq 'skip') { $prefs['Asked'] = $true; try { $prefs | ConvertTo-Json | Set-Content -Path $pf -Encoding UTF8 } catch {}; Send-Json $ctx @{ ok = $true }; return }
            if ($m -notin 'off', 'weekly', 'monitor') { Send-Json $ctx @{ error = 'bad request' } 400; return }
            if ($script:Busy) { Send-Json $ctx @{ error = 'busy' } 409; return }
            $script:LastDry = ($body.dry -eq $true)
            Start-Action ("Set-AutoCare '" + $m + "'") (Get-Text 'act_auto') $script:LastDry
            Send-Json $ctx @{ ok = $true }
        }
        '/api/lang' {
            $l = [string]$body.lang
            if ($l -and $S.PSObject.Properties[$l]) {
                $script:Lang = $l
                try { @{ Lang = $l } | ConvertTo-Json | Set-Content -Path $prefPath -Encoding UTF8 } catch {}
            }
            Send-Json $ctx @{ ok = $true }
        }
        '/api/bye' { $script:ByeAt = (Get-Date).AddSeconds(8); Send-Json $ctx @{ ok = $true } }
        '/api/exit' { $script:Quit = $true; Send-Json $ctx @{ ok = $true } }
        default { Send-Json $ctx @{ error = 'not found' } 404 }
    }
}
$script:LastDry = $false   # set by /api/run so that follow-up dialogs (fix, startup, dns) use the same dry-run choice

Start-InfoRefresh
$url = "$origin/?t=$token"

# ---------------------------------------------------------------- test client (runs in its own runspace and talks plain HTTP)
if ($Test) {
    $res = [hashtable]::Synchronized(@{ Lines = (New-Object System.Collections.ArrayList); Done = $false })
    $testRs = [runspacefactory]::CreateRunspace(); $testRs.Open()
    $testRs.SessionStateProxy.SetVariable('res', $res)
    $testRs.SessionStateProxy.SetVariable('origin', $origin)
    $testRs.SessionStateProxy.SetVariable('token', $token)
    $testRs.SessionStateProxy.SetVariable('all', [bool]$TestAll)
    $testRs.SessionStateProxy.SetVariable('actIds', @($ActionById.Keys | Where-Object { $_ -ne '__hello' -and -not $ActionById[$_].Special } | Sort-Object))
    $tps = [powershell]::Create(); $tps.Runspace = $testRs
    [void]$tps.AddScript(@'
function Out-Line($t) { [void]$res.Lines.Add($t) }
function Call($method, $path, $body, $tok = $token, $hdr = @{}) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    if ($tok) { $wc.Headers['X-Token'] = $tok }
    foreach ($k in $hdr.Keys) { $wc.Headers[$k] = $hdr[$k] }
    try {
        if ($method -eq 'GET') { $t = $wc.DownloadString($origin + $path) }
        else { $wc.Headers['Content-Type'] = 'application/json'; $t = $wc.UploadString($origin + $path, 'POST', ($body | ConvertTo-Json -Compress -Depth 6)) }
        return @{ Code = 200; Text = $t }
    } catch [System.Net.WebException] {
        $code = 0; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ Code = $code; Text = '' }
    }
}
try {
    # security checks
    $r = Call 'GET' '/' $null ''; Out-Line ("page without token  -> {0} (want 403)" -f $r.Code)
    $r = Call 'GET' ('/?t=' + $token) $null ''; Out-Line ("page with token     -> {0} (want 200), {1} bytes, has app: {2}" -f $r.Code, $r.Text.Length, ($r.Text -match 'appName'))
    $r = Call 'GET' '/api/poll?since=0' $null ''; Out-Line ("api without token   -> {0} (want 403)" -f $r.Code)
    $r = Call 'GET' '/api/poll?since=0' $null 'wrong'; Out-Line ("api wrong token     -> {0} (want 403)" -f $r.Code)
    $r = Call 'POST' '/api/run' @{ id = 'act_turbo' } $token @{ Origin = 'http://evil.example' }; Out-Line ("foreign origin POST -> {0} (want 403)" -f $r.Code)
    $r = Call 'POST' '/api/run' @{ id = 'Get-Process' }; Out-Line ("unknown action name  -> {0} (want 400)" -f $r.Code)
    $r = Call 'POST' '/api/startup' @{ mode = 'Disable'; keys = @() }; Out-Line ("empty startup list   -> {0} (want 400)" -f $r.Code)
    $r = Call 'POST' '/api/uninstall' @{ keys = @() }; Out-Line ("empty uninstall list  -> {0} (want 400)" -f $r.Code)
    $r = Call 'POST' '/api/uninstall' @{ keys = @('Win32|machine|x; calc.exe', 'cmd /c calc') }; Out-Line ("unknown program keys -> {0} (want 400)" -f $r.Code)
    $r = Call 'GET' '/api/monitor' $null ''; Out-Line ("monitor without token -> {0} (want 403)" -f $r.Code)
    [void](Call 'GET' '/api/monitor' $null); Start-Sleep -Seconds 6
    $mon = (Call 'GET' '/api/monitor' $null).Text | ConvertFrom-Json
    Out-Line ("monitor sample       -> ram {0} %, processes {1}, drives {2}" -f $mon.m.RamPct, $mon.m.Procs, @($mon.m.Drives).Count)
    $page = (Call 'GET' ('/?t=' + $token) $null '').Text
    $m = [regex]::Match($page, 'const BOOT = (\{.*?\});\r?\n', 'Singleline')
    Out-Line ("page boot data parses: {0}" -f ($m.Success -and [bool]($m.Groups[1].Value | ConvertFrom-Json).cats))

    function RunOne($id) {
        $r = Call 'POST' '/api/run' @{ id = $id; dry = $true; lang = 'en' }
        if ($r.Code -ne 200) { return @{ Ok = $false; Secs = 0; Err = 1; Note = "HTTP $($r.Code)" } }
        $sw = [Diagnostics.Stopwatch]::StartNew(); $since = 0; $errs = 0; $dialog = ''; $answers = 0
        while ($sw.Elapsed.TotalSeconds -lt 240) {
            Start-Sleep -Milliseconds 150
            $p = (Call 'GET' ("/api/poll?since=$since") $null).Text | ConvertFrom-Json
            $since = $p.next
            foreach ($e in $p.events) { if ($e.k -eq 'text' -and ($e.t -match '^Error:' -or $e.t -match '^\s+\[x\]')) { $errs++ } }
            if ($p.prompt) {
                $v = $true
                if ($p.prompt.k -eq 'input') { if ($p.prompt.mode -eq 'all') { $v = 'A' } else { $v = [string]$p.prompt.def } }
                [void](Call 'POST' '/api/answer' @{ id = $p.prompt.id; value = $v }); $answers++
            }
            if ($p.dialog) { $dialog = "$($p.dialog.k):$(@($p.dialog.items).Count)"; [void](Call 'POST' '/api/dialog_close' @{ id = $p.dialog.id }) }
            if (-not $p.busy -and $p.events.Count -ge 0 -and $sw.Elapsed.TotalSeconds -gt 0.4) {
                $q = (Call 'GET' ("/api/poll?since=$since") $null).Text | ConvertFrom-Json
                if (-not $q.busy) { break }
            }
        }
        return @{ Ok = (-not $p.busy); Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); Err = $errs; Note = "dialog=$dialog answers=$answers" }
    }
    $o = RunOne '__hello'; Out-Line ("first action {0,6} s  finished={1}" -f $o.Secs, $o.Ok)
    $ids = @('act_turbo'); if ($all) { $ids = $actIds }
    foreach ($id in $ids) { $o = RunOne $id; Out-Line ("{0,-22} {1,6} s  finished={2} errors={3} {4}" -f $id, $o.Secs, $o.Ok, $o.Err, $o.Note) }
    $r = (Call 'GET' '/api/poll?since=0' $null).Text | ConvertFrom-Json
    Out-Line ("dashboard info present: {0}" -f [bool]$r.info)
    [void](Call 'POST' '/api/exit' @{})
} catch { Out-Line ("TEST ERROR: " + $_.Exception.Message) }
$res.Done = $true
'@)
    [void]$tps.BeginInvoke()
}

# ---------------------------------------------------------------- start the browser window
if ($NoBrowser -and -not $Test) { Write-Output "OPEN: $url"; [Console]::Out.Flush() }
if (-not $Test -and -not $NoBrowser) {
    $edge = $null
    foreach ($c in @(
            ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' -ErrorAction SilentlyContinue).'(default)'),
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction SilentlyContinue).'(default)'),
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
        if ($c -and (Test-Path $c)) { $edge = $c; break }
    }
    if ($edge) {
        $prof = Join-Path $env:TEMP 'turbo_optimizer_browser'
        $ww = 1220; $wh = 820   # fit small screens (1366x768 laptops have about 730 px under the taskbar)
        try { Add-Type -AssemblyName System.Windows.Forms; $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $ww = [math]::Min($ww, $wa.Width - 40); $wh = [math]::Min($wh, $wa.Height - 40) } catch {}
        try { $script:Browser = Start-Process $edge -ArgumentList @("--app=$url", "--window-size=$ww,$wh", "--user-data-dir=$prof", '--no-first-run', '--disable-extensions') -PassThru } catch {}
    }
    if (-not $script:Browser) { Start-Process $url }
}

# ---------------------------------------------------------------- serve
$exitCode = 0
try {
    while (-not $script:Quit) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(100)) {
            Update-Engine
            $now = Get-Date
            if ($Test -and $res.Done) { $script:Quit = $true }
            if ($sync.Quit -and -not $script:Busy) { Start-Sleep -Seconds 2; $script:Quit = $true }
            if (-not $script:Busy -and -not $script:Prompt) {
                if ($script:ByeAt -and $now -gt $script:ByeAt) { $script:Quit = $true }
                if ($script:Browser -and $script:Browser.HasExited -and ($now - $script:LastSeen).TotalSeconds -gt 5) { $script:Quit = $true }
                if (-not $Test -and ($now - $script:LastSeen).TotalMinutes -gt 30) { $script:Quit = $true }
            }
            if ($script:Quit) { break }
        }
        if ($script:Quit -and -not $ar.IsCompleted) { break }
        $ctx = $listener.EndGetContext($ar)
        try {
            Handle-Request $ctx
        } catch {
            Write-UiError 'request' $_
            try { Send-Json $ctx @{ error = 'server error' } 500 } catch {}
        }
    }
} finally {
    try { if ($script:Browser -and -not $script:Browser.HasExited) { [void]$script:Browser.CloseMainWindow() } } catch {}
    try { $listener.Stop(); $listener.Close() } catch {}
    try { if ($script:CurPs) { [void]$script:CurPs.BeginStop($null, $null) }; $sync.Evt.Set(); $rs.Close(); $infoRs.Close() } catch {}
}
if ($Test) {
    foreach ($l in $res.Lines) { Write-Output $l }
    Write-Output '--- ui error log:'
    if (Test-Path $errFile) { Get-Content $errFile -Tail 5 } else { Write-Output '(none)' }
}
exit $exitCode
