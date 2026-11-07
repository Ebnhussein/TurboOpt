<#
  Checks a translations file. Data only: the file is parsed, never executed.
  -Candidate  the file to check
  -Reference  a trusted copy (the main branch); the English block must be identical to it
  Exit code 0 = fine, 1 = problems (listed on screen).
#>
param(
    [Parameter(Mandatory)][string]$Candidate,
    [string]$Reference = ''
)
$ErrorActionPreference = 'Stop'
$problems = New-Object System.Collections.ArrayList
function Bad([string]$m) { [void]$problems.Add($m) }
function Read-Json([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
function Get-Holders([string]$s) { @([regex]::Matches($s, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object) -join ',' }

try { $c = Read-Json $Candidate } catch { Write-Output "not valid JSON: $($_.Exception.Message)"; exit 1 }
if (-not $c.PSObject.Properties['en']) { Bad 'missing the en block' }
else {
    $enKeys = @($c.en.PSObject.Properties.Name)
    foreach ($lang in $c.PSObject.Properties) {
        $code = $lang.Name
        if ($code -notmatch '^[a-z]{2,3}(-[A-Za-z]{2,4})?$') { Bad "language code '$code' is not a short code like de or pt-BR"; continue }
        $keys = @($lang.Value.PSObject.Properties.Name)
        $miss = @($enKeys | Where-Object { $keys -notcontains $_ })
        $extra = @($keys | Where-Object { $enKeys -notcontains $_ })
        if ($miss.Count) { Bad "$code is missing keys: $($miss -join ', ')" }
        if ($extra.Count) { Bad "$code has unknown keys: $($extra -join ', ')" }
        if ($lang.Value.PSObject.Properties['_rtl'] -and "$($lang.Value._rtl)" -notin '0', '1') { Bad "$code _rtl must be 0 or 1" }
        foreach ($k in $enKeys) {
            if (-not $lang.Value.PSObject.Properties[$k]) { continue }
            $v = [string]$lang.Value.$k
            $e = [string]$c.en.$k
            if ($k -eq '_name' -or $k -eq '_rtl') { if (-not $v.Trim()) { Bad "$code.$k is empty" }; continue }
            if (-not $v.Trim()) { Bad "$code.$k is empty"; continue }
            if ($v.Length -gt 400) { Bad "$code.$k is longer than 400 characters" }
            if ($v -match '[<>]') { Bad "$code.$k contains < or >" }
            if ($v -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { Bad "$code.$k contains control characters" }
            if ((Get-Holders $v) -ne (Get-Holders $e)) { Bad "$code.$k must keep the placeholders of the English text ($(Get-Holders $e))" }
        }
    }
    if ($Reference) {
        $r = Read-Json $Reference
        foreach ($k in @($r.en.PSObject.Properties.Name)) {
            if ([string]$r.en.$k -cne [string]$c.en.$k) { Bad "the English text '$k' was changed; English changes need the owner" }
        }
        if (@($r.en.PSObject.Properties.Name).Count -ne $enKeys.Count) { Bad 'the set of English keys was changed' }
    }
}
if ($problems.Count) {
    Write-Output "$($problems.Count) problem(s):"
    $problems | Select-Object -First 40 | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
Write-Output ("translations OK: {0} languages, {1} texts each" -f @($c.PSObject.Properties).Count, @($c.en.PSObject.Properties.Name).Count)
exit 0
