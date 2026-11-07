<#
  Turbo Optimizer - graphical version (English / Arabic, more languages can be added in TurboUI_strings.json)
  Uses the same engine as TurboOptimizer.ps1 and runs it in the background so the window never freezes.
  Run through TurboOptimizerUI.bat.   -Test = build the window, load the engine, check it, optionally save screenshots, exit.
#>
[CmdletBinding()]
param([switch]$Test, [switch]$TestAll, [string]$Shot = '')

$ErrorActionPreference = 'Continue'
$script:T0 = [Diagnostics.Stopwatch]::StartNew()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# Never show the grey "unhandled exception" box (it would freeze the window); write the error to a file instead.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
$script:UiErrFile = Join-Path $PSScriptRoot 'turbo_ui_errors.log'
function Write-UiError([string]$Where, $Err) {
    try { Add-Content -Path $script:UiErrFile -Value ("[{0}] {1}: {2}`r`n    {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Where, $Err.Exception.Message, ("$($Err.ScriptStackTrace)" -replace "`r?`n", ' <- ')) } catch {}
}
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) try { Add-Content -Path $script:UiErrFile -Value ("[{0}] thread exception: {1}`r`n    {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $e.Exception.Message, $e.Exception.StackTrace) } catch {} })

$here = $PSScriptRoot
$corePath = Join-Path $here 'TurboOptimizer.ps1'
$stringsPath = Join-Path $here 'TurboUI_strings.json'
$prefPath = Join-Path $here 'turbo_ui.json'

# ---------------------------------------------------------------- admin
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $Test -and -not (Test-Admin)) {
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    exit
}
if (-not (Test-Path $corePath)) {
    [System.Windows.Forms.MessageBox]::Show("TurboOptimizer.ps1 was not found next to this file:`n$corePath", 'Turbo Optimizer') | Out-Null
    exit 1
}

# ---------------------------------------------------------------- languages
$S = [System.IO.File]::ReadAllText($stringsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$script:Lang = 'en'
if (Test-Path $prefPath) { try { $p = Get-Content $prefPath -Raw | ConvertFrom-Json; if ($p.Lang -and $S.PSObject.Properties[$p.Lang]) { $script:Lang = [string]$p.Lang } } catch {} }
function T([string]$Key) {
    $l = $S.PSObject.Properties[$script:Lang]
    if ($l -and $l.Value.PSObject.Properties[$Key]) { return [string]$l.Value.$Key }
    return [string]$S.en.$Key
}
function Test-Rtl { return ((T '_rtl') -eq '1') }

# ---------------------------------------------------------------- background engine (one persistent runspace)
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
$script:Plat = $null
'@
# A second, separate engine only for the dashboard numbers, so clicking a button never waits for them.
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
        Laptop = $script:Plat.Laptop; VM = $script:Plat.VM; CPU = $script:Sys.CPU; RAM = $script:Sys.RAM
        FreeGB = $free; RamPct = $ram; Startup = $startup
        Notes = @($script:Plat.Notes); High = $(if ($health) { [int]$health.High } else { -1 }); Med = $(if ($health) { [int]$health.Med } else { 0 }); When = $(if ($health) { [string]$health.Time } else { '' })
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
if ($bootErr) { [System.Windows.Forms.MessageBox]::Show("The engine could not start:`n$bootErr", 'Turbo Optimizer') | Out-Null; exit 1 }
$script:BootSec = [math]::Round($script:T0.Elapsed.TotalSeconds, 1)
# dashboard engine
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
$script:InfoPs = $null
$script:InfoAsync = $null
function Start-InfoRefresh {
    if ($script:InfoAsync -and -not $script:InfoAsync.IsCompleted) { return }
    if ($script:InfoPs) { try { $script:InfoPs.Dispose() } catch {}; $script:InfoPs = $null }
    $ps = [powershell]::Create()
    $ps.Runspace = $infoRs
    [void]$ps.AddScript('try { Publish-Info } catch { }')
    $script:InfoPs = $ps
    $script:InfoAsync = $ps.BeginInvoke()
}

# ---------------------------------------------------------------- UI state
$script:Busy = $false
$script:CurPs = $null
$script:CurAsync = $null
$script:Silent = $false
$script:Pending = $null
$script:InTick = $false
$script:Category = 'home'
$script:LastInfo = $null

$colors = @{
    Black = '#cccccc'; DarkBlue = '#5c8dff'; DarkGreen = '#3fb950'; DarkCyan = '#39c5cf'; DarkRed = '#ff6b6b'; DarkMagenta = '#d2a8ff'; DarkYellow = '#d29922'
    Gray = '#cccccc'; DarkGray = '#8b949e'; Blue = '#79c0ff'; Green = '#56d364'; Cyan = '#56d4dd'; Red = '#ff7b72'; Magenta = '#d2a8ff'; Yellow = '#e3b341'; White = '#ffffff'; '' = '#cccccc'
}
function ConvertTo-Color([string]$Name) {
    $hex = $colors[$Name]
    if (-not $hex) { $hex = '#cccccc' }
    return [System.Drawing.ColorTranslator]::FromHtml($hex)
}

# ---------------------------------------------------------------- categories and actions
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
        @{ K = 'act_debloat'; D = 'd_debloat'; Cmd = 'Invoke-Debloat' }) },
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
    @{ Id = 'safety'; K = 'cat_safety'; Actions = @(
        @{ K = 'act_restore'; D = 'd_restore'; Cmd = 'Invoke-RestorePoint' },
        @{ K = 'act_revert'; D = 'd_revert'; Cmd = 'Invoke-Revert' },
        @{ K = 'act_sched_health'; D = 'd_sched_health'; Cmd = 'Register-HealthTask' },
        @{ K = 'act_sched_weekly'; D = 'd_sched_weekly'; Cmd = 'Register-MaintenanceTask' },
        @{ K = 'act_sched_remove'; D = 'd_sched_remove'; Cmd = "foreach (`$t in 'TurboOptimizer Health Check', 'TurboOptimizer Weekly Maintenance') { if (Get-ScheduledTask -TaskName `$t -ErrorAction SilentlyContinue) { Invoke-Act (""Remove `$t"") { Unregister-ScheduledTask -TaskName `$t -Confirm:`$false -ErrorAction Stop } } }" },
        @{ K = 'act_open_log'; D = 'd_open_log'; Special = 'open_log' },
        @{ K = 'act_open_problems'; D = 'd_open_problems'; Special = 'open_problems' },
        @{ K = 'act_open_config'; D = 'd_open_config'; Special = 'open_config' }) }
)

# ---------------------------------------------------------------- the window
$form = New-Object System.Windows.Forms.Form
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Nat { [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l); }'
# fit the screen (1366x768 laptops have only about 730 px of height under the taskbar)
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$fw = [math]::Min(1080, $wa.Width - 24)
$fh = [math]::Min(740, $wa.Height - 16)
$form.StartPosition = 'Manual'
$form.Size = New-Object System.Drawing.Size($fw, $fh)
$form.Location = New-Object System.Drawing.Point(($wa.Left + [int](($wa.Width - $fw) / 2)), ($wa.Top + [int](($wa.Height - $fh) / 2)))
$form.MinimumSize = New-Object System.Drawing.Size([math]::Min(860, $fw), [math]::Min(540, $fh))
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

# log: persistent control (kept when the language changes)
$log = New-Object System.Windows.Forms.RichTextBox
$log.ReadOnly = $true
$log.BackColor = [System.Drawing.Color]::FromArgb(17, 20, 24)
$log.ForeColor = [System.Drawing.Color]::FromArgb(204, 204, 204)
$log.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$log.BorderStyle = 'None'
$log.WordWrap = $true
$log.RightToLeft = 'No'
$log.Dock = 'Fill'

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Top'
$progress.Height = 8
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.AutoSize = $false
$statusLabel.Height = 26
$statusLabel.Dock = 'Top'
$statusLabel.TextAlign = 'MiddleLeft'
$stopBtn = New-Object System.Windows.Forms.Button
$stopBtn.Width = 110
$stopBtn.Height = 30
$stopBtn.Enabled = $false

$script:Ui = @{}   # rebuilt controls

function Add-Log([string]$Text, [string]$Color = 'Gray', [bool]$NoNewline = $false) {
    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = ConvertTo-Color $Color
    $log.AppendText($(if ($NoNewline) { $Text } else { $Text + "`n" }))
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}
function Set-BusyUI([bool]$Busy) {
    foreach ($c in @($script:Ui.Cards)) { $c.Enabled = -not $Busy }
    foreach ($c in @($script:Ui.CatButtons)) { $c.Enabled = -not $Busy }
    $stopBtn.Enabled = $Busy
    if ($Busy) { $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30; $statusLabel.Text = (T 'working') }
    else { $progress.Style = 'Blocks'; $progress.MarqueeAnimationSpeed = 0; $progress.Value = 0; $statusLabel.Text = (T 'ready') }
}

# ---------------------------------------------------------------- running things in the engine
function Start-Action([string]$Cmd, [string]$Title) {
    if ($script:Busy) { return }
    $script:Busy = $true
    $script:ActionStart = Get-Date
    $script:WorkText = (T 'working')
    Set-BusyUI $true
    Add-Log ("`n=== $Title ===") 'Cyan'
    $dry = '$false'
    if ($script:Ui.Dry.Checked) { $dry = '$true' }
    $lang = 'en'
    if ($script:Lang -eq 'ar') { $lang = 'ar' }
    $Cmd = $Cmd.Replace('{LANG}', $lang)
    $code = @"
`$script:DryRun = $dry
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

# ---------------------------------------------------------------- dialogs
function Get-MsgOptions {
    if (Test-Rtl) { return ([System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign) }
    return [System.Windows.Forms.MessageBoxOptions]0
}
function Show-AskDialog([string]$Text) {
    if ($script:TestMode) { Add-Log "  (test) answered YES: $($Text.Trim())" 'DarkGray'; return $true }
    $r = [System.Windows.Forms.MessageBox]::Show($form, $Text.Trim(), (T 'app'), 'YesNo', 'Question', 'Button2', (Get-MsgOptions))
    return ($r -eq 'Yes')
}
function Show-InputDialog([string]$Prompt, [string]$Default = '') {
    if ($script:TestMode) { Add-Log "  (test) input skipped: $($Prompt.Trim())" 'DarkGray'; return $Default }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = (T 'app'); $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.ClientSize = New-Object System.Drawing.Size(520, 160); $d.Font = $form.Font
    if (Test-Rtl) { $d.RightToLeft = 'Yes'; $d.RightToLeftLayout = $true }
    $l = New-Object System.Windows.Forms.Label; $l.Text = $Prompt.Trim(); $l.SetBounds(14, 12, 492, 70)
    $t = New-Object System.Windows.Forms.TextBox; $t.Text = $Default; $t.SetBounds(14, 88, 492, 26); $t.RightToLeft = 'No'
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = (T 'dlg_ok'); $ok.DialogResult = 'OK'; $ok.SetBounds(316, 122, 90, 28)
    $cn = New-Object System.Windows.Forms.Button; $cn.Text = (T 'dlg_cancel'); $cn.DialogResult = 'Cancel'; $cn.SetBounds(414, 122, 90, 28)
    $d.Controls.AddRange(@($l, $t, $ok, $cn)); $d.AcceptButton = $ok; $d.CancelButton = $cn
    $res = ''
    if ($d.ShowDialog($form) -eq 'OK') { $res = $t.Text }
    $d.Dispose()
    return $res
}
function New-ListDialog([string]$Title, [string[]]$Columns, [int[]]$Widths, [int]$Height = 520) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $Title; $d.StartPosition = 'CenterParent'; $d.Font = $form.Font
    $d.ClientSize = New-Object System.Drawing.Size(860, $Height); $d.MinimumSize = New-Object System.Drawing.Size(700, 420)
    if (Test-Rtl) { $d.RightToLeft = 'Yes'; $d.RightToLeftLayout = $true }
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.HideSelection = $false
    for ($i = 0; $i -lt $Columns.Count; $i++) { [void]$lv.Columns.Add($Columns[$i], $Widths[$i]) }
    return @{ Form = $d; List = $lv }
}
function Show-FindingsDialog($Items) {
    if ($Items.Count -eq 0) { Add-Log ('  ' + (T 'msg_no_findings')) 'Green'; return }
    if ($script:TestMode) { Add-Log "  (test) findings window would list $($Items.Count) items" 'DarkGray'; return }
    $x = New-ListDialog (T 'dlg_findings') @((T 'col_sev'), (T 'col_problem'), (T 'col_fix')) @(90, 540, 200) 560
    $d = $x.Form; $lv = $x.List
    $lv.Dock = 'Top'; $lv.Height = 300
    $detail = New-Object System.Windows.Forms.TextBox
    $detail.Multiline = $true; $detail.ReadOnly = $true; $detail.ScrollBars = 'Vertical'; $detail.Dock = 'Top'; $detail.Height = 130; $detail.RightToLeft = 'No'; $detail.BackColor = 'White'
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 48; $bar.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
    if (Test-Rtl) { $bar.FlowDirection = 'RightToLeft' }
    $fixBtn = New-Object System.Windows.Forms.Button; $fixBtn.Text = (T 'dlg_fix'); $fixBtn.Width = 150; $fixBtn.Height = 30
    $ignBtn = New-Object System.Windows.Forms.Button; $ignBtn.Text = (T 'dlg_ignore'); $ignBtn.Width = 150; $ignBtn.Height = 30
    $clsBtn = New-Object System.Windows.Forms.Button; $clsBtn.Text = (T 'dlg_close'); $clsBtn.Width = 110; $clsBtn.Height = 30; $clsBtn.DialogResult = 'Cancel'
    $bar.Controls.AddRange(@($fixBtn, $ignBtn, $clsBtn))
    $d.Controls.Add($detail); $d.Controls.Add($lv); $d.Controls.Add($bar)
    $lv.BringToFront(); $detail.BringToFront()
    foreach ($f in $Items) {
        $fixText = (T 'fix_none')
        if ($f.Fix) { $fixText = (T ('fix_' + $f.Fix)) }
        if ($f.Download) { $fixText += " ($($f.Download))" }
        $it = New-Object System.Windows.Forms.ListViewItem((T ('sev_' + $f.Sev)))
        [void]$it.SubItems.Add($f.Title); [void]$it.SubItems.Add($fixText)
        $it.Tag = $f
        if ($f.Sev -eq 'HIGH') { $it.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30) } elseif ($f.Sev -eq 'MED') { $it.ForeColor = [System.Drawing.Color]::FromArgb(170, 100, 0) } else { $it.ForeColor = [System.Drawing.Color]::FromArgb(90, 100, 112) }
        if ($f.Fix -and $f.Sev -ne 'INFO') { $it.Checked = $true }
        [void]$lv.Items.Add($it)
    }
    $lv.add_SelectedIndexChanged({ if ($lv.SelectedItems.Count -gt 0) { $detail.Text = [string]$lv.SelectedItems[0].Tag.Detail } }.GetNewClosure())
    $mode = @{ Value = '' }
    $fixBtn.add_Click({ $mode.Value = 'Fix'; $d.DialogResult = 'OK'; $d.Close() }.GetNewClosure())
    $ignBtn.add_Click({ $mode.Value = 'Ignore'; $d.DialogResult = 'OK'; $d.Close() }.GetNewClosure())
    [void]$d.ShowDialog($form)
    $ids = @()
    if ($mode.Value) { foreach ($i in $lv.CheckedItems) { $ids += [string]$i.Tag.Id } }
    $d.Dispose()
    if ($ids.Count -gt 0) {
        $sync.Ids = $ids
        $script:Pending = @{ Cmd = ("Invoke-DoctorFixSelected -Ids @(`$sync.Ids) -Mode '" + $mode.Value + "'"); Title = (T 'dlg_findings') }
    }
}
function Show-StartupDialog($Items) {
    if ($script:TestMode) { Add-Log "  (test) startup window would list $($Items.Count) items" 'DarkGray'; return }
    $x = New-ListDialog (T 'dlg_startup') @((T 'col_program'), (T 'col_command')) @(240, 580) 520
    $d = $x.Form; $lv = $x.List
    $lv.Dock = 'Fill'
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 50; $bar.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
    if (Test-Rtl) { $bar.FlowDirection = 'RightToLeft' }
    $disBtn = New-Object System.Windows.Forms.Button; $disBtn.Text = (T 'dlg_disable'); $disBtn.Width = 150; $disBtn.Height = 30
    $delBtn = New-Object System.Windows.Forms.Button; $delBtn.Text = (T 'dlg_delay'); $delBtn.Width = 150; $delBtn.Height = 30
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = (T 'dlg_minutes'); $lbl.AutoSize = $true; $lbl.Margin = New-Object System.Windows.Forms.Padding(8, 8, 2, 0)
    $num = New-Object System.Windows.Forms.NumericUpDown; $num.Minimum = 1; $num.Maximum = 30; $num.Value = 2; $num.Width = 56
    $clsBtn = New-Object System.Windows.Forms.Button; $clsBtn.Text = (T 'dlg_close'); $clsBtn.Width = 100; $clsBtn.Height = 30; $clsBtn.DialogResult = 'Cancel'
    $bar.Controls.AddRange(@($disBtn, $delBtn, $lbl, $num, $clsBtn))
    $d.Controls.Add($lv); $d.Controls.Add($bar); $lv.BringToFront()
    foreach ($s in $Items) {
        $name = [string]$s.Name
        if ($s.Protected) { $name += "  [$(T 'tag_protected')]" }
        $it = New-Object System.Windows.Forms.ListViewItem($name)
        [void]$it.SubItems.Add([string]$s.Command)
        $it.Tag = $s
        if ($s.Protected) { $it.ForeColor = [System.Drawing.Color]::Gray }
        [void]$lv.Items.Add($it)
    }
    $mode = @{ Value = '' }
    $disBtn.add_Click({ $mode.Value = 'Disable'; $d.DialogResult = 'OK'; $d.Close() }.GetNewClosure())
    $delBtn.add_Click({ $mode.Value = 'Delay'; $d.DialogResult = 'OK'; $d.Close() }.GetNewClosure())
    [void]$d.ShowDialog($form)
    $keys = @()
    if ($mode.Value) { foreach ($i in $lv.CheckedItems) { if (-not $i.Tag.Protected) { $keys += [string]$i.Tag.Key } } }
    $mins = [int]$num.Value
    $d.Dispose()
    if ($keys.Count -gt 0) {
        $sync.Keys = $keys
        $script:Pending = @{ Cmd = ("Invoke-StartupBatch -Mode '" + $mode.Value + "' -Keys @(`$sync.Keys) -Minutes " + $mins); Title = (T 'dlg_startup') }
    }
}
function Show-DnsDialog {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = (T 'dlg_dns'); $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.ClientSize = New-Object System.Drawing.Size(420, 240); $d.Font = $form.Font
    if (Test-Rtl) { $d.RightToLeft = 'Yes'; $d.RightToLeftLayout = $true }
    $opts = @('Cloudflare (1.1.1.1)', 'Google (8.8.8.8)', 'Quad9 (9.9.9.9)', (T 'dlg_auto'))
    $radios = @()
    for ($i = 0; $i -lt 4; $i++) { $r = New-Object System.Windows.Forms.RadioButton; $r.Text = $opts[$i]; $r.AutoSize = $true; $r.Location = New-Object System.Drawing.Point(24, (20 + 36 * $i)); $d.Controls.Add($r); $radios += $r }
    $radios[0].Checked = $true
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = (T 'dlg_ok'); $ok.DialogResult = 'OK'; $ok.SetBounds(214, 192, 90, 30)
    $cn = New-Object System.Windows.Forms.Button; $cn.Text = (T 'dlg_cancel'); $cn.DialogResult = 'Cancel'; $cn.SetBounds(312, 192, 90, 30)
    $d.Controls.AddRange(@($ok, $cn)); $d.AcceptButton = $ok; $d.CancelButton = $cn
    $pick = -1
    if ($d.ShowDialog($form) -eq 'OK') { for ($i = 0; $i -lt 4; $i++) { if ($radios[$i].Checked) { $pick = $i } } }
    $d.Dispose()
    if ($pick -ge 0 -and $pick -le 2) { return @{ Cmd = "Set-DnsProvider `$script:DnsProviders[$pick]"; Title = (T 'act_dns_switch') } }
    if ($pick -eq 3) { return @{ Cmd = "Set-DnsProvider @{ N = 'Automatic'; Auto = `$true }"; Title = (T 'act_dns_switch') } }
    return $null
}

# ---------------------------------------------------------------- reading engine messages
function Update-Dashboard($m) {
    $script:LastInfo = $m
    if ($script:Ui.PcLabel) {
        $kind = 'desktop'
        if ($m.VM) { $kind = 'VM' } elseif ($m.Laptop) { $kind = 'laptop' }
        $script:Ui.PcLabel.Text = "$($m.Vendor) $($m.Model)  |  $($m.Caption) ($($m.Build))  |  $kind"
        $script:Ui.StatFree.Text = ('{0} GB' -f $m.FreeGB)
        $script:Ui.StatRam.Text = ('{0} %' -f $m.RamPct)
        $script:Ui.StatStartup.Text = [string]$m.Startup
        if ($m.High -lt 0) { $script:Ui.StatHealth.Text = (T 'stat_unknown'); $script:Ui.StatHealth.ForeColor = [System.Drawing.Color]::Gray }
        elseif ($m.High -eq 0 -and $m.Med -eq 0) { $script:Ui.StatHealth.Text = (T 'stat_ok'); $script:Ui.StatHealth.ForeColor = [System.Drawing.Color]::FromArgb(30, 130, 60) }
        else {
            $script:Ui.StatHealth.Text = ((T 'stat_issues') -f $m.High, $m.Med)
            if ($m.High -gt 0) { $script:Ui.StatHealth.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30) } else { $script:Ui.StatHealth.ForeColor = [System.Drawing.Color]::FromArgb(170, 100, 0) }
        }
    }
}
function Show-Message($msg) {
    switch ($msg.K) {
        'text' { Add-Log $msg.T $msg.C $msg.N }
        'ask' { $sync.Answer = (Show-AskDialog $msg.T); $sync.Evt.Set() }
        'input' {
            $p = [string]$msg.T
            if ($p -match 'A = all safe ones') { if (Show-AskDialog (T 'msg_clean_all')) { $sync.Answer = 'A' } else { $sync.Answer = '' } }
            else {
                $def = ''
                if ($p -match '\[(\d+)\]\s*:?\s*$') { $def = $Matches[1] }
                $sync.Answer = (Show-InputDialog $p $def)
            }
            $sync.Evt.Set()
        }
        'work' { if ($msg.T) { $script:WorkText = [string]$msg.T } else { $script:WorkText = (T 'working') } }
        'step' { $progress.Style = 'Blocks'; $progress.Maximum = [int]$msg.N; $progress.Value = [math]::Max(0, [math]::Min([int]$msg.N, [int]$msg.I - 1)); $script:WorkText = ('{0}/{1}  {2}' -f $msg.I, $msg.N, $msg.T) }
        'findings' { Show-FindingsDialog @($msg.Items) }
        'startup' { Show-StartupDialog @($msg.Items) }
        'info' { Update-Dashboard $msg }
        'done' {
            $script:Busy = $false
            $secs = [int]((Get-Date) - $script:ActionStart).TotalSeconds
            Add-Log ('--- ' + (T 'msg_done') + "  ($secs s)") 'DarkGray'
            Set-BusyUI $false
            Start-InfoRefresh
            if ($script:Pending) { $p = $script:Pending; $script:Pending = $null; Start-Action $p.Cmd $p.Title }
        }
    }
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 60
$timer.add_Tick({
    if ($script:InTick) { return }
    $script:InTick = $true
    try {
        $msg = $null
        $n = 0
        $paint = (-not $sync.Q.IsEmpty)
        # draw the log once per batch instead of once per line
        if ($paint) { [void][Nat]::SendMessage($log.Handle, 0x000B, [IntPtr]0, [IntPtr]::Zero) }
        try {
            while ($n -lt 300 -and $sync.Q.TryDequeue([ref]$msg)) {
                $n++
                try { Show-Message $msg } catch { Write-UiError "message $($msg.K)" $_; if ($msg.K -eq 'ask' -or $msg.K -eq 'input') { $sync.Answer = $null; $sync.Evt.Set() } }
            }
        } finally {
            if ($paint) {
                [void][Nat]::SendMessage($log.Handle, 0x000B, [IntPtr]1, [IntPtr]::Zero)
                if ($log.TextLength -gt 300000) { $log.Select(0, 100000); $log.SelectedText = ''; $log.SelectionStart = $log.TextLength }
                $log.SelectionStart = $log.TextLength; $log.ScrollToCaret(); $log.Invalidate()
            }
        }
        if ($script:Busy -and $script:ActionStart) {
            $statusLabel.Text = ('{0}   ({1} s)' -f $script:WorkText, [int]((Get-Date) - $script:ActionStart).TotalSeconds)
        }
        if ($script:InfoAsync -and $script:InfoAsync.IsCompleted -and $script:InfoPs) {
            try { $script:InfoPs.EndInvoke($script:InfoAsync) | Out-Null } catch {}
            $script:InfoPs.Dispose(); $script:InfoPs = $null; $script:InfoAsync = $null
        }
        if ($script:Busy -and $script:CurAsync -and $script:CurAsync.IsCompleted -and $sync.Q.IsEmpty) {
            # the engine finished without sending 'done' (it was stopped or crashed)
            $errs = @($script:CurPs.Streams.Error)
            foreach ($e in ($errs | Select-Object -First 3)) { Add-Log ('Error: ' + $e.ToString()) 'Red' }
            $script:CurPs.Dispose(); $script:CurPs = $null; $script:CurAsync = $null
            Show-Message @{ K = 'done' }
        } elseif ($script:CurAsync -and $script:CurAsync.IsCompleted -and $script:CurPs) {
            try { $script:CurPs.EndInvoke($script:CurAsync) | Out-Null } catch {}
            $script:CurPs.Dispose(); $script:CurPs = $null; $script:CurAsync = $null
        }
    } finally { $script:InTick = $false }
})

# ---------------------------------------------------------------- building the screen
function New-StatCard([string]$Title) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.BackColor = 'White'; $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
    $t = New-Object System.Windows.Forms.Label; $t.Text = $Title; $t.ForeColor = [System.Drawing.Color]::Gray; $t.Dock = 'Top'; $t.Height = 24; $t.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 0); $t.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $v = New-Object System.Windows.Forms.Label; $v.Text = '...'; $v.Dock = 'Fill'; $v.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0); $v.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $v.RightToLeft = 'No'      # numbers and units keep their order (7.57 GB) in every language
    if (Test-Rtl) { $v.TextAlign = 'MiddleRight' } else { $v.TextAlign = 'MiddleLeft' }
    $p.Controls.Add($v); $p.Controls.Add($t)
    return @{ Panel = $p; Value = $v }
}
function New-Card($Act) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size = New-Object System.Drawing.Size(250, 92); $p.BackColor = 'White'; $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 10); $p.Cursor = 'Hand'
    $p.BorderStyle = 'FixedSingle'
    $t = New-Object System.Windows.Forms.Label; $t.Text = (T $Act.K); $t.Dock = 'Top'; $t.Height = 28; $t.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
    $t.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10); $t.ForeColor = [System.Drawing.Color]::FromArgb(25, 40, 60)
    $d = New-Object System.Windows.Forms.Label; $d.Text = (T $Act.D); $d.Dock = 'Fill'; $d.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 4)
    $d.ForeColor = [System.Drawing.Color]::FromArgb(95, 105, 118); $d.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $p.Controls.Add($d); $p.Controls.Add($t)
    $click = { Invoke-Card $Act }.GetNewClosure()
    $enter = { $p.BackColor = [System.Drawing.Color]::FromArgb(232, 241, 255); $t.BackColor = $p.BackColor; $d.BackColor = $p.BackColor }.GetNewClosure()
    $leave = { $p.BackColor = [System.Drawing.Color]::White; $t.BackColor = $p.BackColor; $d.BackColor = $p.BackColor }.GetNewClosure()
    foreach ($c in @($p, $t, $d)) { $c.add_Click($click); $c.add_MouseEnter($enter); $c.add_MouseLeave($leave) }
    return $p
}
function Invoke-Card($Act) {
    if ($script:Busy) { return }
    switch ($Act.Special) {
        'dns' { $r = Show-DnsDialog; if ($r) { Start-Action $r.Cmd $r.Title } }
        'open_log' { $f = Join-Path $here 'turbo_log.txt'; if (Test-Path $f) { Start-Process notepad $f } }
        'open_problems' { $f = Join-Path $here 'turbo_errors.log'; if (Test-Path $f) { Start-Process notepad $f } else { Add-Log (T 'msg_no_findings') 'Green' } }
        'open_config' { $f = Join-Path $here 'config.ini'; if (Test-Path $f) { Start-Process notepad $f } }
        default { Start-Action $Act.Cmd (T $Act.K) }
    }
}
function Show-Category([string]$Id) {
    $script:Category = $Id
    $script:Ui.Actions.SuspendLayout()
    $script:Ui.Actions.Controls.Clear()
    $cards = @()
    foreach ($c in $Categories) {
        if ($c.Id -ne $Id) { continue }
        foreach ($a in $c.Actions) { $card = New-Card $a; $script:Ui.Actions.Controls.Add($card); $cards += $card }
    }
    $script:Ui.Cards = $cards
    $script:Ui.Actions.ResumeLayout()
    foreach ($b in @($script:Ui.CatButtons)) {
        if ($b.Tag -eq $Id) { $b.BackColor = [System.Drawing.Color]::FromArgb(44, 62, 88) } else { $b.BackColor = [System.Drawing.Color]::FromArgb(31, 42, 55) }
    }
}
function Build-UI {
    $rtl = Test-Rtl
    $savedRtf = $null
    if ($log.TextLength -gt 0) { $savedRtf = $log.Rtf }
    $form.SuspendLayout()
    # keep the controls that live across language changes: take them out of their parents before the old panels are disposed
    foreach ($keep in @($log, $progress, $statusLabel, $stopBtn)) { if ($keep.Parent) { $keep.Parent.Controls.Remove($keep) } }
    foreach ($c in @($form.Controls)) { $form.Controls.Remove($c); $c.Dispose() }
    if ($rtl) { $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true } else { $form.RightToLeft = 'No'; $form.RightToLeftLayout = $false }
    $form.Text = (T 'app')
    $script:Ui = @{}

    # content area
    $content = New-Object System.Windows.Forms.Panel; $content.Dock = 'Fill'; $content.Padding = New-Object System.Windows.Forms.Padding(14, 8, 14, 8)
    $note = New-Object System.Windows.Forms.Label; $note.Text = (T 'note_log'); $note.Dock = 'Top'; $note.Height = 22; $note.ForeColor = [System.Drawing.Color]::Gray; $note.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $actions = New-Object System.Windows.Forms.FlowLayoutPanel; $actions.Dock = 'Top'; $actions.AutoSize = $true; $actions.AutoSizeMode = 'GrowAndShrink'; $actions.WrapContents = $true; $actions.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    if ($rtl) { $actions.FlowDirection = 'RightToLeft' }
    $stats = New-Object System.Windows.Forms.TableLayoutPanel; $stats.Dock = 'Top'; $stats.Height = 76; $stats.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $stats.ColumnCount = 4; $stats.RowCount = 1
    foreach ($w in 22, 22, 22, 34) { [void]$stats.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', $w))) }
    [void]$stats.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    $sf = New-StatCard (T 'stat_free'); $sr = New-StatCard (T 'stat_ram'); $ss = New-StatCard (T 'stat_startup'); $sh = New-StatCard (T 'stat_health')
    $stats.Controls.Add($sf.Panel, 0, 0); $stats.Controls.Add($sr.Panel, 1, 0); $stats.Controls.Add($ss.Panel, 2, 0); $stats.Controls.Add($sh.Panel, 3, 0)
    $pc = New-Object System.Windows.Forms.Label; $pc.Dock = 'Top'; $pc.Height = 24; $pc.Text = (T 'loading'); $pc.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5); $pc.ForeColor = [System.Drawing.Color]::FromArgb(25, 40, 60)
    $logHost = New-Object System.Windows.Forms.Panel; $logHost.Dock = 'Fill'; $logHost.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    $log.Dock = 'Fill'; $logHost.Controls.Add($log)
    $content.Controls.Add($logHost); $content.Controls.Add($note); $content.Controls.Add($actions); $content.Controls.Add($stats); $content.Controls.Add($pc)

    # bottom bar
    $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 46; $bottom.BackColor = 'White'; $bottom.Padding = New-Object System.Windows.Forms.Padding(14, 4, 14, 4)
    $stopBtn.Text = (T 'stop'); $stopBtn.Dock = if ($rtl) { 'Left' } else { 'Right' }
    $statusLabel.Dock = 'Fill'; $statusLabel.Text = (T 'ready')
    $progress.Dock = 'Top'
    $bottom.Controls.Add($statusLabel); $bottom.Controls.Add($stopBtn); $bottom.Controls.Add($progress)

    # top bar
    $top = New-Object System.Windows.Forms.Panel; $top.Dock = 'Top'; $top.Height = 54; $top.BackColor = [System.Drawing.Color]::FromArgb(22, 31, 42)
    $title = New-Object System.Windows.Forms.Label; $title.Text = (T 'app'); $title.ForeColor = 'White'; $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14); $title.AutoSize = $false; $title.Dock = if ($rtl) { 'Right' } else { 'Left' }; $title.Width = 240; $title.TextAlign = 'MiddleLeft'; $title.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
    if ($rtl) { $title.TextAlign = 'MiddleRight' }
    $tools = New-Object System.Windows.Forms.FlowLayoutPanel; $tools.Dock = if ($rtl) { 'Left' } else { 'Right' }; $tools.Width = 520; $tools.Padding = New-Object System.Windows.Forms.Padding(10, 12, 10, 0); $tools.FlowDirection = if ($rtl) { 'RightToLeft' } else { 'LeftToRight' }
    $dry = New-Object System.Windows.Forms.CheckBox; $dry.Text = (T 'dry'); $dry.ForeColor = 'White'; $dry.AutoSize = $true; $dry.Margin = New-Object System.Windows.Forms.Padding(6, 4, 14, 0)
    if ($script:DryChecked) { $dry.Checked = $true }
    $dry.add_CheckedChanged({ $script:DryChecked = $dry.Checked }.GetNewClosure())
    $langLbl = New-Object System.Windows.Forms.Label; $langLbl.Text = (T 'lang'); $langLbl.ForeColor = 'White'; $langLbl.AutoSize = $true; $langLbl.Margin = New-Object System.Windows.Forms.Padding(6, 5, 4, 0)
    $combo = New-Object System.Windows.Forms.ComboBox; $combo.DropDownStyle = 'DropDownList'; $combo.Width = 130
    $codes = @()
    foreach ($p in $S.PSObject.Properties) { [void]$combo.Items.Add([string]$p.Value._name); $codes += $p.Name }
    $combo.SelectedIndex = [array]::IndexOf($codes, $script:Lang)
    $combo.add_SelectedIndexChanged({
        $new = $codes[$combo.SelectedIndex]
        if ($new -ne $script:Lang) {
            $script:Lang = $new
            try { @{ Lang = $new } | ConvertTo-Json | Set-Content -Path $prefPath -Encoding UTF8 } catch {}
            Build-UI
        }
    }.GetNewClosure())
    $tools.Controls.AddRange(@($dry, $langLbl, $combo))
    $top.Controls.Add($tools); $top.Controls.Add($title)

    # sidebar
    $side = New-Object System.Windows.Forms.Panel; $side.Dock = if ($rtl) { 'Right' } else { 'Left' }; $side.Width = 210; $side.BackColor = [System.Drawing.Color]::FromArgb(31, 42, 55)
    $catButtons = @()
    foreach ($c in ($Categories | Sort-Object { [array]::IndexOf(@($Categories), $_) } -Descending)) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = (T $c.K); $b.Tag = $c.Id; $b.Dock = 'Top'; $b.Height = 48; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
        $b.ForeColor = 'White'; $b.BackColor = [System.Drawing.Color]::FromArgb(31, 42, 55); $b.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $b.TextAlign = if ($rtl) { 'MiddleRight' } else { 'MiddleLeft' }; $b.Padding = New-Object System.Windows.Forms.Padding(14, 0, 14, 0); $b.Cursor = 'Hand'
        $b.add_Click({ param($s, $e) if (-not $script:Busy) { Show-Category ([string]$s.Tag) } })
        $side.Controls.Add($b); $catButtons += $b
    }
    $script:Ui.CatButtons = $catButtons

    $form.Controls.Add($content); $form.Controls.Add($side); $form.Controls.Add($bottom); $form.Controls.Add($top)
    $script:Ui.Actions = $actions; $script:Ui.PcLabel = $pc; $script:Ui.Dry = $dry
    $script:Ui.StatFree = $sf.Value; $script:Ui.StatRam = $sr.Value; $script:Ui.StatStartup = $ss.Value; $script:Ui.StatHealth = $sh.Value
    $form.ResumeLayout($true)
    Show-Category $script:Category
    if ($savedRtf) { $log.Rtf = $savedRtf }
    if ($script:LastInfo) { Update-Dashboard $script:LastInfo }
    Set-BusyUI $script:Busy
}

$stopBtn.add_Click({
    if ($script:Busy -and $script:CurPs) {
        if (Show-AskDialog (T 'msg_stop')) {
            try { [void]$script:CurPs.BeginStop($null, $null) } catch {}
            $sync.Answer = $false; $sync.Evt.Set()
            Add-Log ('--- ' + (T 'msg_stopped')) 'Yellow'
        }
    }
})
$form.add_FormClosing({
    try { $timer.Stop() } catch {}
    try { if ($script:CurPs) { [void]$script:CurPs.BeginStop($null, $null) }; $sync.Evt.Set(); $rs.Close(); $infoRs.Close() } catch {}
})

# ---------------------------------------------------------------- start
Build-UI
$timer.Start()
Start-InfoRefresh

if ($Test) {
    # automated check: build, load, run actions in dry-run through the same path as the buttons, measure, screenshot
    $script:TestMode = $true
    function Pump([scriptblock]$Until, [int]$TimeoutSec) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec -and -not (& $Until)) {
            $b = [Diagnostics.Stopwatch]::StartNew()
            [System.Windows.Forms.Application]::DoEvents()
            if ($b.ElapsedMilliseconds -gt $script:MaxBlockMs) { $script:MaxBlockMs = $b.ElapsedMilliseconds }
            Start-Sleep -Milliseconds 40
        }
        return [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
    $script:MaxBlockMs = 0
    $form.Show()
    Write-Output ("window shown after {0} s (engine loaded in {1} s)" -f [math]::Round($script:T0.Elapsed.TotalSeconds, 1), $script:BootSec)
    $script:Ui.Dry.Checked = $true
    # click straight away, while the dashboard is still loading: the action must start at once
    $t1 = [Diagnostics.Stopwatch]::StartNew()
    Start-Action 'Say ''hello from the engine'' Green' 'latency test'
    $lat = Pump { $log.Text -match 'hello from the engine' } 15
    Write-Output ("first output reached the screen after {0} s while dashboard loaded: {1}" -f $lat, (-not [bool]$script:LastInfo))
    [void](Pump { -not $script:Busy } 20)
    $d = Pump { [bool]$script:LastInfo } 90
    Write-Output ("dashboard arrived after {0} s more: {1}" -f $d, [bool]$script:LastInfo)
    $todo = @()
    if ($TestAll) {
        foreach ($c in $Categories) { foreach ($a in $c.Actions) { if ($a.Cmd) { $todo += @{ Name = $a.K; Cmd = $a.Cmd } } } }
    } else { $todo = @(@{ Name = 'act_turbo'; Cmd = 'Invoke-Turbo' }) }
    foreach ($a in $todo) {
        $before = $log.TextLength
        $e = Pump { -not $script:Busy } 0
        Start-Action $a.Cmd (T $a.Name)
        $secs = Pump { -not $script:Busy } 200
        $txt = $log.Text.Substring([math]::Min($before, $log.TextLength))
        $errs = @(($txt -split "`n") | Where-Object { $_ -match '^Error:|^\s+\[x\]' }).Count
        Write-Output ("{0,-22} {1,6} s   finished={2}   errors={3}" -f $a.Name, $secs, (-not $script:Busy), $errs)
        if ($script:Busy) { try { $script:CurPs.BeginStop($null, $null) | Out-Null } catch {}; [void](Pump { -not $script:Busy } 10) }
    }
    Write-Output ("longest time the window was frozen: {0} ms" -f $script:MaxBlockMs)
    $script:Ui.Dry.Checked = $false
    if ($Shot) {
        New-Item -ItemType Directory -Force $Shot | Out-Null
        $form.TopMost = $true
        foreach ($lg in 'en', 'ar') {
            $script:Lang = $lg; Build-UI; Show-Category 'home'
            $form.Activate()
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500; [System.Windows.Forms.Application]::DoEvents()
            $r = $form.Bounds
            $bmp = New-Object System.Drawing.Bitmap($r.Width, $r.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($r.Location, [System.Drawing.Point]::Empty, $r.Size)
            $g.Dispose()
            $bmp.Save((Join-Path $Shot "ui_$lg.png"), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        }
        $form.TopMost = $false
        Write-Output "screenshots saved to $Shot"
    }
    $form.Close()
    exit 0
}[void]$form.ShowDialog()
