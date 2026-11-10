<#
  Tests the program removal and monitor logic without touching any real program.
  The leftover finder runs on a temporary folder tree and a temporary registry key under HKCU:\Software.
  Exit code 0 = all passed.
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'app\TurboOptimizer.ps1') -AsLibrary
$script:fails = 0
function Check([string]$Name, $Ok) { if ($Ok) { Write-Output "PASS  $Name" } else { Write-Output "FAIL  $Name"; $script:fails++ } }

# ---- name matching
Check 'name key: version and architecture are ignored' ((Get-ProgNameKey '7-Zip 23.01 (x64)') -eq '7zip' -and (Get-ProgNameKey 'Python 3.12.1 (64-bit)') -eq 'python' -and (Get-ProgNameKey 'Notepad++') -eq 'notepad')
Check 'name key: names without latin letters give no key' ((Get-ProgNameKey ([string][char]0x0628 + [char]0x0631)) -eq '')

# ---- how a program is removed
$msi = '{11111111-2222-3333-4444-555555555555}'
$pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = $msi; QuietUninstallString = ''; UninstallString = "MsiExec.exe /I$msi"; PackageFullName = '' })
Check 'plan: MSI program is removed quietly with msiexec /x' ($pl.Mode -eq 'msi' -and $pl.File -eq 'msiexec.exe' -and $pl.Args -eq "/x $msi /qn /norestart")
$pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = ''; UninstallString = "MsiExec.exe /X$msi"; PackageFullName = '' })
Check 'plan: msiexec in the uninstall string is turned into a quiet removal' ($pl.Mode -eq 'msi' -and $pl.Args -eq "/x $msi /qn /norestart")
$pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = '"C:\Program Files\App One\unins000.exe" /VERYSILENT'; UninstallString = '"C:\Program Files\App One\unins000.exe"'; PackageFullName = '' })
Check 'plan: quiet string with a quoted path' ($pl.Mode -eq 'quiet' -and $pl.File -eq 'C:\Program Files\App One\unins000.exe' -and $pl.Args -eq '/VERYSILENT')
$pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = ''; UninstallString = 'C:\Program Files\App Two\uninst.exe /S'; PackageFullName = '' })
Check 'plan: unquoted path with spaces is split at .exe' ($pl.Mode -eq 'interactive' -and $pl.File -eq 'C:\Program Files\App Two\uninst.exe' -and $pl.Args -eq '/S')
$pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = ''; UninstallString = 'not a command'; PackageFullName = '' })
Check 'plan: unusable string -> none' ($pl.Mode -eq 'none')
$pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Store'; Msi = ''; QuietUninstallString = ''; UninstallString = ''; PackageFullName = 'Vendor.App_1.0.0.0_x64__abc' })
Check 'plan: Store app uses its package name' ($pl.Mode -eq 'store' -and $pl.Args -eq 'Vendor.App_1.0.0.0_x64__abc')
Check 'protected: runtimes and redistributables' ((Test-ProgramProtected ([pscustomobject]@{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable (x64)' })) -and (Test-ProgramProtected ([pscustomobject]@{ Name = 'Microsoft .NET Runtime - 8.0.1 (x64)' })))
Check 'protected: an ordinary program is not' (-not (Test-ProgramProtected ([pscustomobject]@{ Name = '7-Zip 23.01 (x64)' })))

# ---- leftovers, on a temporary tree
$tmp = Join-Path $env:TEMP ('turbotest_' + [guid]::NewGuid().ToString('N'))
$regBase = 'HKCU:\Software\TurboOptTest_' + [guid]::NewGuid().ToString('N')
try {
    foreach ($d in 'PF\7-Zip\sub', 'PF\7-Zip Extras', 'PF\Microsoft', 'PF\OtherApp', 'PF\Vendor', 'AD\7zip', 'AD\Packages', 'SM') { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Set-Content -Path (Join-Path $tmp 'PF\7-Zip\sub\a.txt') -Value 'x'
    Set-Content -Path (Join-Path $tmp 'AD\7zip\b.txt') -Value 'x'
    Set-Content -Path (Join-Path $tmp 'SM\7-Zip.lnk') -Value 'x'
    Set-Content -Path (Join-Path $tmp 'SM\Other.lnk') -Value 'x'
    New-Item -Path $regBase -Force | Out-Null
    foreach ($k in '7-Zip', 'Other', 'Vendor\7-Zip') { New-Item -Path (Join-Path $regBase $k) -Force | Out-Null }
    $p = [pscustomobject]@{ Kind = 'Win32'; Name = '7-Zip 23.01 (x64)'; Publisher = 'Vendor'; InstallLocation = (Join-Path $tmp 'PF\7-Zip'); RegPath = 'HKCU:\Software\NoSuchKeyForTest'; PackageFullName = '' }
    $r = @(Find-Leftovers $p -FileRoots @((Join-Path $tmp 'PF'), (Join-Path $tmp 'AD')) -RegBases @($regBase) -ShortcutRoots @((Join-Path $tmp 'SM')))
    $paths = @($r | ForEach-Object { $_.Path.ToLower() })
    $has = { param($rel) $paths -contains (Join-Path $tmp $rel).ToLower() }
    Check 'leftovers: the install folder is found' (& $has 'PF\7-Zip')
    Check 'leftovers: a folder with the same name elsewhere is found' (& $has 'AD\7zip')
    Check 'leftovers: an empty publisher folder is found' (& $has 'PF\Vendor')
    Check 'leftovers: the shortcut is found' (& $has 'SM\7-Zip.lnk')
    Check 'leftovers: a similar name is NOT taken' (-not (& $has 'PF\7-Zip Extras'))
    Check 'leftovers: Microsoft, other apps and other shortcuts are NOT taken' (-not (& $has 'PF\Microsoft') -and -not (& $has 'PF\OtherApp') -and -not (& $has 'AD\Packages') -and -not (& $has 'SM\Other.lnk'))
    $regFound = @($r | Where-Object { $_.Type -eq 'Registry' } | ForEach-Object { $_.Display.ToLower() })
    $short = { param($sub) @($regFound | Where-Object { $_ -like ('*' + $regBase.Substring(5).ToLower() + '\' + $sub.ToLower()) }).Count -eq 1 }
    Check 'leftovers: registry key with the program name is found' (& $short '7-Zip')
    Check 'leftovers: registry key under the publisher is found' (& $short 'Vendor\7-Zip')
    Check 'leftovers: the publisher key is found once it would be empty' (& $short 'Vendor')
    Check 'leftovers: an unrelated registry key is NOT taken' (-not (& $short 'Other'))
    $none = [pscustomobject]@{ Kind = 'Win32'; Name = 'ab'; Publisher = ''; InstallLocation = ''; RegPath = 'HKCU:\Software\NoSuchKeyForTest'; PackageFullName = '' }
    Check 'leftovers: a name that is too short matches nothing' (@(Find-Leftovers $none -FileRoots @((Join-Path $tmp 'PF')) -RegBases @($regBase) -ShortcutRoots @((Join-Path $tmp 'SM'))).Count -eq 0)

    # nothing is deleted in a dry run
    $script:DryRun = $true
    foreach ($l in $r) { Remove-Leftover $l | Out-Null }
    $script:DryRun = $false
    Check 'dry run: nothing was deleted' ((Test-Path (Join-Path $tmp 'PF\7-Zip')) -and (Test-Path (Join-Path $regBase '7-Zip')) -and (Test-Path (Join-Path $tmp 'SM\7-Zip.lnk')))
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $regBase -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- real uninstaller runs, with small fake programs (compiled here, they only touch their own temporary folder and key)
function New-FakeExe([string]$Path, [string]$Marker) {
    $bytes = ([Text.Encoding]::ASCII.GetBytes($Marker) | ForEach-Object { [string]$_ }) -join ','
    $src = @"
using System; using System.IO; using System.Diagnostics; using System.Threading; using Microsoft.Win32;
public class FakeUninst {
    static byte[] M = new byte[] { $bytes };
    static void Wipe() {
        string k = Environment.GetEnvironmentVariable("FAKE_KEY"), d = Environment.GetEnvironmentVariable("FAKE_DIR");
        if (!string.IsNullOrEmpty(k)) { try { Registry.CurrentUser.DeleteSubKeyTree(k, false); } catch { } }
        if (!string.IsNullOrEmpty(d)) { try { Directory.Delete(d, true); } catch { } }
    }
    public static int Main(string[] a) {
        if (M.Length == 0) return 9;
        string all = string.Join(" ", a);
        if (all.Contains("--sleep")) { Thread.Sleep(60000); return 0; }
        if (all.Contains("--child")) { Thread.Sleep(3000); Wipe(); return 0; }
        if (all.Contains("--relaunch")) { Process.Start(Environment.GetCommandLineArgs()[0], "--child"); return 0; }
        if (all.Contains("/S") || all.Contains("--now")) { Thread.Sleep(500); Wipe(); return 0; }
        return 5;
    }
}
"@
    Add-Type -TypeDefinition $src -OutputAssembly $Path -OutputType ConsoleApplication -ReferencedAssemblies 'System.dll'
}
$ft = Join-Path $env:TEMP ('turbofake_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ft -Force | Out-Null
$fakeKeys = @()
try {
    $nsis = Join-Path $ft 'uninstall.exe'; New-FakeExe $nsis 'Nullsoft Install System v3.08'
    $plain = Join-Path $ft 'remove.exe'; New-FakeExe $plain 'plain'
    $inno = Join-Path $ft 'unins000.exe'; [IO.File]::WriteAllText($inno, 'MZ fake Inno Setup Messages (6.2.0)')
    Check 'installer kind: NSIS is recognised from the file' ((Get-InstallerKind $nsis) -eq 'nsis')
    Check 'installer kind: Inno Setup is recognised from the file' ((Get-InstallerKind $inno) -eq 'inno')
    Check 'installer kind: an unknown installer is left alone' ((Get-InstallerKind $plain) -eq '')
    $pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = ''; UninstallString = ('"{0}"' -f $inno); PackageFullName = '' })
    Check 'plan: Inno uninstaller gets the quiet switches' ($pl.Mode -eq 'quiet' -and $pl.Kind -eq 'inno' -and $pl.Args -match '/VERYSILENT' -and $pl.Original -eq '')
    $pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = ''; UninstallString = ('"{0}"' -f $nsis); PackageFullName = '' })
    Check 'plan: NSIS uninstaller gets /S' ($pl.Mode -eq 'quiet' -and $pl.Kind -eq 'nsis' -and $pl.Args -eq '/S')
    $pl = Get-UninstallPlan ([pscustomobject]@{ Kind = 'Win32'; Msi = ''; QuietUninstallString = ''; UninstallString = ('"{0}"' -f $plain); PackageFullName = '' })
    Check 'plan: an unknown uninstaller still opens its own screens' ($pl.Mode -eq 'interactive' -and $pl.Kind -eq '')

    $run = {
        param($exe, $mode, $extra, $kind)
        $key = 'Software\TurboOptFake_' + [guid]::NewGuid().ToString('N')
        $dir = Join-Path $ft ('app_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null; Set-Content (Join-Path $dir 'x.txt') 'x'
        [void][Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($key).Dispose()
        $env:FAKE_KEY = $key; $env:FAKE_DIR = $dir
        $script:fakeKeys += $key
        $P = [pscustomobject]@{ Kind = 'Win32'; Name = 'Fake'; RegPath = ('Registry::HKEY_CURRENT_USER\' + $key); PackageFullName = '' }
        $plan = @{ Mode = $mode; File = $exe; Args = $extra; Kind = $kind; Original = '' }
        $r = Invoke-ProgramUninstaller $P $plan
        return @{ R = $r; KeyGone = -not (Test-Path -LiteralPath $P.RegPath); DirGone = -not (Test-Path -LiteralPath $dir) }
    }
    $x = & $run $nsis 'quiet' '/S' 'nsis'
    Check 'uninstaller run: a quiet uninstaller removes the program and is detected as gone' ($x.R.Ran -and $x.R.Gone -and $x.KeyGone -and $x.DirGone -and $x.R.Code -eq 0)
    $x = & $run $nsis 'quiet' '--relaunch' 'nsis'
    Check 'uninstaller run: an uninstaller that relaunches itself and exits is still waited for' ($x.R.Ran -and $x.R.Gone -and $x.KeyGone)
    $x = & $run $plain 'quiet' '' ''
    Check 'uninstaller run: an uninstaller that does nothing is reported as not gone (nothing else touched)' ($x.R.Ran -and -not $x.R.Gone -and -not $x.KeyGone)
    $x = & $run (Join-Path $ft 'missing.exe') 'quiet' '/S' ''
    Check 'uninstaller run: a missing uninstaller is reported as not run' (-not $x.R.Ran -and -not $x.R.Gone)
    # ending a process by name: a sleeping fake program is ended, protected and odd names are refused
    $sl = Join-Path $ft 'turbotest_sleeper.exe'; New-FakeExe $sl 'sleeper'
    $sp = Start-Process -FilePath $sl -ArgumentList '--sleep' -PassThru
    Start-Sleep -Milliseconds 500
    Check 'end process: a normal program is ended by name' ((Stop-ProcessByName 'turbotest_sleeper') -ge 1)
    Start-Sleep -Milliseconds 500
    Check 'end process: it is really gone' (-not (Get-Process -Id $sp.Id -ErrorAction SilentlyContinue))
    Check 'end process: protected and unsafe names are refused' ((Stop-ProcessByName 'explorer') -eq -1 -and (Stop-ProcessByName 'lsass') -eq -1 -and (Stop-ProcessByName 'powershell') -eq -1 -and (Stop-ProcessByName 'a*') -eq -1 -and (Stop-ProcessByName 'x; calc') -eq -1)
} finally {
    foreach ($k in $fakeKeys) { try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($k, $false) } catch {} }
    Get-Process -Name 'turbotest_sleeper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\FAKE_KEY, Env:\FAKE_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ft -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- tips, performance history and the summary, from made-up numbers
$base = @{ Cpu = 20; RamPct = 40; DiskPct = 10; TempC = 50; Battery = $null; Charging = $null; UptimeSec = 3600; Drives = @(@{ Name = 'C:'; FreeGB = 200; SizeGB = 500 }); TopCpu = @(@{ Name = 'busyapp'; Cpu = 40; MemMB = 300; N = 1 }); TopRam = @(@{ Name = 'bigapp'; Cpu = 1; MemMB = 4000; N = 3 }) }
Check 'tips: a calm PC has none' (@(Get-MonitorTips $base).Count -eq 0)
$hot = @{} + $base; $hot.Cpu = 95; $hot.RamPct = 95; $hot.TempC = 90; $hot.Battery = 10; $hot.Charging = $false; $hot.UptimeSec = 20 * 86400; $hot.DiskPct = 99
$hot.Drives = @(@{ Name = 'C:'; FreeGB = 20; SizeGB = 500 }, @{ Name = 'D:'; FreeGB = 400; SizeGB = 500 })
$ids = @(Get-MonitorTips $hot | ForEach-Object { $_.Id })
Check 'tips: every kind of problem is reported once' (($ids -contains 'cpu_high') -and ($ids -contains 'ram_high') -and ($ids -contains 'temp_high') -and ($ids -contains 'battery_low') -and ($ids -contains 'uptime_long') -and ($ids -contains 'disk_busy') -and (@($ids | Where-Object { $_ -eq 'disk_low' }).Count -eq 1))
$ramTip = @(Get-MonitorTips $hot | Where-Object { $_.Id -eq 'ram_high' })[0]
Check 'tips: the memory tip names the biggest program' ($ramTip.A1 -eq 'bigapp' -and $ramTip.A2 -eq '4000' -and $ramTip.Level -eq 'bad')
Check 'tips: every tip has English text for the console' (@(Get-MonitorTips $hot | Where-Object { (Get-TipText $_) -match '^[a-z_]+$' }).Count -eq 0)

$pf = Join-Path $env:TEMP ('turboperf_' + [guid]::NewGuid().ToString('N') + '.csv')
$script:PerfFile = $pf
try {
    Add-PerfSample $base
    Check 'history: a sample is written with a header and one line' ((Get-Content $pf).Count -eq 2 -and (Get-Content $pf)[0] -match '^ts,cpu')
    $lines = New-Object System.Collections.ArrayList
    $now = Get-Date
    for ($i = 0; $i -lt 200; $i++) {
        $t = $now.AddMinutes(-5 * (200 - $i)); $cpu = 10; $ram = 50
        if ($i -ge 100 -and $i -le 103) { $cpu = 92; $ram = 70 }     # one slow stretch
        if ($i -eq 150) { $cpu = 30; $ram = 96 }                    # a memory peak later
        [void]$lines.Add(('{0},{1},{2},5,100,60,app{3},{4}.5,mem{3},{5}' -f $t.ToString('yyyy-MM-dd HH:mm:ss'), $cpu, $ram, $i, $cpu, 500))
    }
    Set-Content -LiteralPath $pf -Value (@('ts,cpu,ram,disk,net,temp,topcpu,topcpupct,topram,topmb') + $lines) -Encoding ASCII
    $sum = Get-PerfSummary 24 $pf
    Check 'history: summary counts the samples and averages them' ($sum.Count -eq 200 -and $sum.MaxCpu -eq 92 -and $sum.MaxRam -eq 96 -and $sum.AvgCpu -ge 10 -and $sum.AvgCpu -le 15)
    Check 'history: the chart series has at most 96 points' (@($sum.Points).Count -ge 50 -and @($sum.Points).Count -le 96)
    Check 'history: the worst moments are separate and name the busiest program' (@($sum.Worst).Count -eq 2 -and $sum.Worst[0].Ram -eq 96 -and $sum.Worst[1].Cpu -eq 92 -and $sum.Worst[1].TopCpu -match '^app10[0-3]$')
    Check 'history: a short window leaves older samples out' ((Get-PerfSummary 1 $pf).Count -le 13)
    Check 'history: a missing file gives an empty summary' ((Get-PerfSummary 24 ($pf + '.none')).Count -eq 0)
    Set-Content -LiteralPath $pf -Value @('ts,cpu,ram,disk,net,temp,topcpu,topcpupct,topram,topmb', 'garbage line', ($now.ToString('yyyy-MM-dd HH:mm:ss') + ',x,1,1,1,1,a,1,b,1')) -Encoding ASCII
    Check 'history: damaged lines are skipped, not fatal' ((Get-PerfSummary 24 $pf).Count -eq 0)
} finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }

# ---- real machine, read-only
$sumry = Get-DeviceSummary
Check 'summary: the score is 0-100 and equals the sum of its six parts' ($sumry.Score -ge 0 -and $sumry.Score -le 100 -and @($sumry.Parts).Count -eq 6 -and ((@($sumry.Parts | ForEach-Object { $_.Pts }) | Measure-Object -Sum).Sum -eq $sumry.Score))
Check 'summary: the tips and the sample convert to JSON' ((ConvertTo-Json -InputObject $sumry -Depth 6 -Compress).Length -gt 100)
$progs = @(Get-InstalledPrograms)
Check 'installed programs: the list can be read and every item has a key and a name' ($progs.Count -ge 0 -and @($progs | Where-Object { -not $_.Key -or -not $_.Name }).Count -eq 0)
$m = Get-MonitorSample
Check 'monitor: memory, processes and drives are read' ($m.RamPct -ge 1 -and $m.RamPct -le 100 -and $m.Procs -gt 0 -and $m.Drives.Count -ge 1)
Check 'monitor: the sample converts to JSON' ((ConvertTo-Json -InputObject $m -Depth 6 -Compress).Length -gt 50)

if ($script:fails -gt 0) { Write-Output "$script:fails check(s) failed"; exit 1 }
Write-Output 'all program and monitor checks passed'
exit 0
