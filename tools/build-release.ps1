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

$appFiles = 'TurboOptimizer.ps1', 'TurboOptimizerWeb.ps1', 'TurboWeb.html', 'TurboUI_strings.json', 'config.ini'
foreach ($f in $appFiles) { Copy-Item (Join-Path $root "app\$f") (Join-Path $stage 'app') }
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
Switch on "Dry run" at the top of the app (or press D in the console). The tool then only
describes what it would do and changes nothing. Try the Doctor first.

SAFE TO TRY
- It asks before closing any program.
- Every change is recorded. Use "Undo changes" (console option 20) to reverse it.
- The tool works offline except for what you ask: updates, downloads, DNS tests.

REQUIREMENTS
Windows 10 (1809 or newer) or Windows 11. For the browser version: Microsoft Edge or Google Chrome.

REMOVE
Delete this folder. The tool installs nothing. Scheduled tasks you created inside it can be
removed from the Safety menu first.

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
$notes = "**Easiest:** open PowerShell and paste ``irm https://ebnhussein.github.io/TurboOpt/i.txt | iex``.`n`n**Or download ``TurboOptimizer-$Tag.zip`` below** (not the 'Source code' files), unzip it, and double-click ``Start Turbo Optimizer.bat``. Windows 10 (1809+) or Windows 11. Switch on Dry run first to change nothing.`n`n$body"
[System.IO.File]::WriteAllText((Join-Path $dist 'notes.md'), $notes, (New-Object System.Text.UTF8Encoding($false)))
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText("$zipPath.sha256", "$hash  TurboOptimizer-$Tag.zip`n", [System.Text.Encoding]::ASCII)
Remove-Item (Join-Path $dist 'stage') -Recurse -Force
"built $zipPath ({0:N0} KB)" -f ((Get-Item $zipPath).Length / 1KB)
