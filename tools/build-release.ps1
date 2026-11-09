<#
  Builds the download package for people who only want to use the tool (not develop it).
  Result: dist\TurboOptimizer-<tag>.zip containing
      Start Turbo Optimizer.bat   (the only thing to double-click)
      README.txt
      LICENSE
      app\                        (engine, browser page, translations, config)
  Also writes dist\notes.md (the release notes) from docs\CHANGELOG.md.
  Usage: .\tools\build-release.ps1 -Tag v11.1
#>
param([Parameter(Mandatory)][string]$Tag)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ver = $Tag.TrimStart('v')
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "stage\TurboOptimizer-$Tag"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $stage 'app') | Out-Null

$appFiles = 'TurboOptimizer.ps1', 'TurboOptimizerWeb.ps1', 'config.ini'
foreach ($f in $appFiles) { Copy-Item (Join-Path $root "app\$f") (Join-Path $stage 'app') }
# the page and the translations travel inside the web script, so the user gets 3 files, not 5
$webPath = Join-Path $stage 'app\TurboOptimizerWeb.ps1'
$web = [System.IO.File]::ReadAllText($webPath)
$b64s = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $root 'app\TurboUI_strings.json')))
$b64h = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $root 'app\TurboWeb.html')))
$mS = [regex]::new("(?m)^\`$EmbeddedStrings = ''")
$mH = [regex]::new("(?m)^\`$EmbeddedHtml = ''")
if (-not $mS.IsMatch($web) -or -not $mH.IsMatch($web)) { throw 'The web script has no embed markers' }
$web = $mS.Replace($web, { param($m) '$EmbeddedStrings = ''' + $b64s + '''' }, 1)
$web = $mH.Replace($web, { param($m) '$EmbeddedHtml = ''' + $b64h + '''' }, 1)
[System.IO.File]::WriteAllText($webPath, $web, (New-Object System.Text.UTF8Encoding($false)))
# the BIOS guides travel inside the engine
$enginePath = Join-Path $stage 'app\TurboOptimizer.ps1'
$eng = [System.IO.File]::ReadAllText($enginePath)
$mG = [regex]::new("(?m)^\`$EmbeddedGuides = ''")
if (-not $mG.IsMatch($eng)) { throw 'The engine has no guides marker' }
$b64g = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $root 'app\bios-guides.json')))
$eng = $mG.Replace($eng, { param($m) '$EmbeddedGuides = ''' + $b64g + '''' }, 1)
$engBom = [System.IO.File]::ReadAllBytes($enginePath)[0] -eq 0xEF
[System.IO.File]::WriteAllText($enginePath, $eng, (New-Object System.Text.UTF8Encoding($engBom)))
Copy-Item (Join-Path $root 'LICENSE') $stage

# the single launcher the user sees
$bat = @"
@echo off
rem Turbo Optimizer - double-click this file. Everything else is in the app folder.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\TurboOptimizer.ps1" %*
if errorlevel 1 pause
"@
[System.IO.File]::WriteAllText((Join-Path $stage 'Start Turbo Optimizer.bat'), ($bat -replace "`r?`n", "`r`n") + "`r`n", [System.Text.Encoding]::ASCII)

$readme = @"
Turbo Optimizer $Tag
Free Windows 10/11 optimizer, cleaner and repair tool.
https://github.com/Ebnhussein/TurboOpt

HOW TO USE
1. Unzip this folder anywhere (not inside the ZIP window).
2. Double-click "Start Turbo Optimizer.bat". Windows asks for administrator rights.
3. The app opens in your browser. On the first run it asks if you want automatic care (weekly cleanup, or a daily watch that fixes safe problems).

FIRST TIME
Try the Doctor first: it only looks and shows what it found. Nothing changes until you confirm.

SAFE TO TRY
- It asks before closing any program.
- Every change is recorded. Use "Undo changes" (console option 20) to reverse it.
- The tool works offline except for what you ask: updates, downloads, DNS tests.

REQUIREMENTS
Windows 10 (1809 or newer) or Windows 11. For the browser version: Microsoft Edge or Google Chrome.

REMOVE
Open Safety and tools, then Uninstall (console: option 22). It removes the scheduled tasks and
the saved data. Then delete this folder. The tool installs nothing else.

Languages: English, Arabic, Spanish, French, German, Portuguese, Russian, Chinese, Hindi, Turkish.
License: MIT (see LICENSE).
"@
[System.IO.File]::WriteAllText((Join-Path $stage 'README.txt'), ($readme -replace "`r?`n", "`r`n") + "`r`n", [System.Text.Encoding]::ASCII)

# zip with forward slashes in entry names so every extractor is happy
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $dist "TurboOptimizer-$Tag.zip"
$base = Split-Path -Parent $stage
$fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
foreach ($file in Get-ChildItem $stage -Recurse -File) {
    $name = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $name, [System.IO.Compression.CompressionLevel]::Optimal)
}
$zip.Dispose(); $fs.Dispose()

# release notes: the matching section of CHANGELOG.md
$cl = Get-Content (Join-Path $root 'docs\CHANGELOG.md') -Raw
$m = [regex]::Match($cl, "(?ms)^## v$([regex]::Escape($ver))\s*\r?\n(.*?)(?=^## v|\z)")
$body = if ($m.Success) { $m.Groups[1].Value.Trim() } else { 'See the changelog.' }
$notes = "**Easiest:** open PowerShell and paste ``irm https://ebnhussein.github.io/TurboOpt/i.txt | iex``.`n`n**Or download ``TurboOptimizer-$Tag.zip`` below** (not the 'Source code' files), unzip it, and double-click ``Start Turbo Optimizer.bat``. Windows 10 (1809+) or Windows 11. Nothing changes until you confirm.`n`n$body"
[System.IO.File]::WriteAllText((Join-Path $dist 'notes.md'), $notes, (New-Object System.Text.UTF8Encoding($false)))
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText("$zipPath.sha256", "$hash  TurboOptimizer-$Tag.zip`n", [System.Text.Encoding]::ASCII)
Remove-Item (Join-Path $dist 'stage') -Recurse -Force
"built $zipPath ({0:N0} KB)" -f ((Get-Item $zipPath).Length / 1KB)
