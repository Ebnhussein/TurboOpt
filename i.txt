<#
  Turbo Optimizer - one-line installer and launcher.

      irm https://ebnhussein.github.io/TurboOpt/i.txt | iex

  It downloads the latest release from GitHub, checks its SHA-256, puts the files in
  %LOCALAPPDATA%\TurboOptimizer\app (your settings and undo history are kept when you update),
  and opens the app in your browser as administrator. Nothing else is installed.

  Options (set before running, for example  $env:TURBO_NOLAUNCH = '1'):
      TURBO_DIR       install folder (default: %LOCALAPPDATA%\TurboOptimizer)
      TURBO_ZIP       use this local ZIP instead of downloading (for offline use and tests)
      TURBO_NOLAUNCH  1 = install only, do not start the app
#>
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$repo = 'Ebnhussein/TurboOpt'
$dir = $env:TURBO_DIR
if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA 'TurboOptimizer' }
$appDir = Join-Path $dir 'app'
$tmp = Join-Path $env:TEMP ('turbo_install_' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
Say ''
Say '  Turbo Optimizer' White
Say '  Free Windows 10/11 optimizer, cleaner and repair tool' DarkGray
Say ''

if ($PSVersionTable.PSVersion.Major -lt 5) { Say '  This needs Windows PowerShell 5.1 or newer (Windows 10 / 11).' Red; return }
if ($env:OS -ne 'Windows_NT') { Say '  Turbo Optimizer runs on Windows only.' Red; return }

try {
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = $env:TURBO_ZIP
    $tag = 'local'
    if ($zip) {
        if (-not (Test-Path $zip)) { throw "ZIP not found: $zip" }
    } else {
        Say '  Looking for the latest version...' Cyan
        $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'TurboOptimizer-installer' }
        $tag = [string]$rel.tag_name
        $asset = @($rel.assets | Where-Object { $_.name -like 'TurboOptimizer-v*.zip' })[0]
        if (-not $asset) { throw 'The latest release has no download file.' }
        $zip = Join-Path $tmp $asset.name
        Say ("  Downloading {0} ({1:N0} KB)..." -f $asset.name, ($asset.size / 1KB)) Cyan
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'TurboOptimizer-installer' }
        $shaAsset = @($rel.assets | Where-Object { $_.name -eq ($asset.name + '.sha256') })[0]
        if ($shaAsset) {
            $raw = (Invoke-WebRequest -Uri $shaAsset.browser_download_url -UseBasicParsing -Headers @{ 'User-Agent' = 'TurboOptimizer-installer' }).Content
            if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::ASCII.GetString($raw) }
            $want = ([string]$raw).Trim().Split(' ')[0].ToLower()
            $have = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
            if ($want -ne $have) { throw "The download is damaged (checksum mismatch). Try again." }
            Say '  Checksum OK.' DarkGray
        }
    }
    $stage = Join-Path $tmp 'x'
    Expand-Archive -Path $zip -DestinationPath $stage -Force
    $src = @(Get-ChildItem $stage -Recurse -Directory -Filter app | Select-Object -First 1)[0]
    if (-not $src) { throw 'The package has no app folder.' }
    New-Item -ItemType Directory -Force $appDir | Out-Null
    foreach ($f in Get-ChildItem $src.FullName -File) {
        $dest = Join-Path $appDir $f.Name
        if ($f.Name -eq 'config.ini' -and (Test-Path $dest)) { continue }     # keep the user's own settings
        Copy-Item $f.FullName $dest -Force
    }
    Get-ChildItem $appDir -File | ForEach-Object { try { Unblock-File $_.FullName } catch {} }
    Say ("  Installed {0} in {1}" -f $tag, $appDir) Green
} catch {
    Say ("  Could not install: " + $_.Exception.Message) Red
    return
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($env:TURBO_NOLAUNCH -eq '1') { return }

$engine = Join-Path $appDir 'TurboOptimizer.ps1'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say '  Opening Turbo Optimizer in your browser (it needs administrator rights)...' Cyan
$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $engine), '-Browser')
if ($isAdmin) { Start-Process powershell -ArgumentList $a } else { Start-Process powershell -Verb RunAs -ArgumentList $a }
Say '  To open it again later: the same command, or the file above.' DarkGray
Say ''
