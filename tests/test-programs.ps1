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

# ---- real machine, read-only
$progs = @(Get-InstalledPrograms)
Check 'installed programs: the list can be read and every item has a key and a name' ($progs.Count -ge 0 -and @($progs | Where-Object { -not $_.Key -or -not $_.Name }).Count -eq 0)
$m = Get-MonitorSample
Check 'monitor: memory, processes and drives are read' ($m.RamPct -ge 1 -and $m.RamPct -le 100 -and $m.Procs -gt 0 -and $m.Drives.Count -ge 1)
Check 'monitor: the sample converts to JSON' ((ConvertTo-Json -InputObject $m -Depth 6 -Compress).Length -gt 50)

if ($script:fails -gt 0) { Write-Output "$script:fails check(s) failed"; exit 1 }
Write-Output 'all program and monitor checks passed'
exit 0
