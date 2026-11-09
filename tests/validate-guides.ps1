<#
  Checks the BIOS guide data file. Data only: the file is parsed, never executed.
  -Candidate  the file to check
  Exit code 0 = fine, 1 = problems (listed on screen).
#>
param([Parameter(Mandatory)][string]$Candidate)
$ErrorActionPreference = 'Stop'
$problems = New-Object System.Collections.ArrayList
function Bad([string]$m) { [void]$problems.Add($m) }
$stepKeys = @('ahci', 'uefi', 'secureboot', 'legacy')
$sample = ('Dell Inc. HP Hewlett-Packard LENOVO ASUSTeK Acer Micro-Star Inspiron N5110 ThinkPad X1 Latitude 7420 ' * 3)

function Check-Text([string]$Where, $Value, [int]$Max = 300) {
    $s = [string]$Value
    if (-not $s.Trim()) { Bad "$Where is empty"; return }
    if ($s.Length -gt $Max) { Bad "$Where is longer than $Max characters" }
    if ($s -match '<') { Bad "$Where contains <" }     # > is allowed: menu paths are written like Advanced > SATA Operation
    if ($s -match 'https?://|www\.') { Bad "$Where contains a link (put links in the pull request, not in the data)" }
    if ($s -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { Bad "$Where contains control characters" }
}
function Check-Regex([string]$Where, $Value) {
    $s = [string]$Value
    if (-not $s) { Bad "$Where is missing"; return }
    if ($s.Length -gt 80) { Bad "$Where is longer than 80 characters"; return }
    try {
        $r = New-Object System.Text.RegularExpressions.Regex($s, 'IgnoreCase', [TimeSpan]::FromMilliseconds(200))
        [void]$r.IsMatch($sample)
    } catch { Bad "$Where is not a safe regular expression: $($_.Exception.Message)" }
}
function Check-Steps($Where, $Steps) {
    if ($null -eq $Steps) { return }
    foreach ($p in $Steps.PSObject.Properties) {
        if ($stepKeys -notcontains $p.Name) { Bad "$Where has an unknown step '$($p.Name)' (allowed: $($stepKeys -join ', '))"; continue }
        Check-Text "$Where.steps.$($p.Name)" $p.Value
    }
}
function Check-Entry($Where, $E, [string[]]$Allowed) {
    foreach ($p in $E.PSObject.Properties) { if ($Allowed -notcontains $p.Name) { Bad "$Where has an unknown field '$($p.Name)'" } }
    if ($E.PSObject.Properties['enter']) { Check-Text "$Where.enter" $E.enter 160 }
    if ($E.PSObject.Properties['boot_menu']) { Check-Text "$Where.boot_menu" $E.boot_menu 160 }
    if ($E.PSObject.Properties['note']) { Check-Text "$Where.note" $E.note }
    if ($E.PSObject.Properties['uefi'] -and $E.uefi -isnot [bool]) { Bad "$Where.uefi must be true or false" }
    if ($E.PSObject.Properties['verified'] -and $E.verified -isnot [bool]) { Bad "$Where.verified must be true or false" }
    if ($E.PSObject.Properties['steps']) { Check-Steps $Where $E.steps }
}

try { $d = [System.IO.File]::ReadAllText($Candidate, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { Write-Output "not valid JSON: $($_.Exception.Message)"; exit 1 }
foreach ($p in $d.PSObject.Properties) { if (@('version', 'generic', 'makers', 'models') -notcontains $p.Name) { Bad "unknown top-level field '$($p.Name)'" } }
if ($d.version -ne 1) { Bad 'version must be 1' }
if (-not $d.generic) { Bad 'generic is missing' } else { Check-Entry 'generic' $d.generic @('enter', 'boot_menu', 'steps', 'note') }
$mk = @($d.makers); $md = @($d.models)
if ($mk.Count -gt 200) { Bad 'too many makers' }
if ($md.Count -gt 3000) { Bad 'too many models' }
$i = 0
foreach ($m in $mk) { $i++; Check-Regex "makers[$i].match" $m.match; Check-Entry "makers[$i]" $m @('match', 'enter', 'boot_menu', 'steps', 'note', 'uefi', 'verified') }
$i = 0
foreach ($m in $md) { $i++; Check-Regex "models[$i].maker" $m.maker; Check-Regex "models[$i].model" $m.model; Check-Entry "models[$i]" $m @('maker', 'model', 'enter', 'boot_menu', 'steps', 'note', 'uefi', 'verified') }
if ($problems.Count) {
    Write-Output "$($problems.Count) problem(s):"
    $problems | Select-Object -First 40 | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
Write-Output ("guides OK: {0} makers, {1} models" -f $mk.Count, $md.Count)
exit 0
