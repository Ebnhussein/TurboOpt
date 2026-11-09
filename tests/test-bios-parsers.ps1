<#
  Tests the BIOS, boot and guide logic with recorded samples instead of real hardware.
  Fixtures in tests/fixtures describe what a vendor interface returns; add a file there to cover a new model.
  Exit code 0 = all passed.
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'app\TurboOptimizer.ps1') -AsLibrary
$script:fails = 0
function Check([string]$Name, $Ok) { if ($Ok) { Write-Output "PASS  $Name" } else { Write-Output "FAIL  $Name"; $script:fails++ } }

# ---- SMBIOS "UEFI supported" flag (Type 0, extension byte 2, bit 3)
function New-Smbios([int]$Len, [int]$Ext2) {
    $b = New-Object System.Collections.Generic.List[byte]
    $s = New-Object byte[] $Len; $s[0] = 0; $s[1] = $Len
    if ($Len -gt 0x13) { $s[0x13] = $Ext2 }
    $b.AddRange($s); $b.AddRange([byte[]](65, 0, 66, 0, 0))       # two strings, then the end marker
    $b.AddRange([byte[]](127, 4, 0, 0, 0, 0)); $b.AddRange((New-Object byte[] 32))
    return $b.ToArray()
}
Check 'SMBIOS: legacy-only BIOS (0x05) -> false' ((Get-SmbiosUefiFlag (New-Smbios 24 0x05)) -eq $false)
Check 'SMBIOS: UEFI BIOS (0x0D) -> true' ((Get-SmbiosUefiFlag (New-Smbios 24 0x0D)) -eq $true)
Check 'SMBIOS: old table without extension byte -> unknown' ($null -eq (Get-SmbiosUefiFlag (New-Smbios 18 0)))
Check 'SMBIOS: garbage -> unknown' ($null -eq (Get-SmbiosUefiFlag ([byte[]](1, 2, 3))))

# ---- vendor interfaces through recorded samples
$script:Fx = $null
function Get-CimInstance {
    param($Namespace, $ClassName, $ErrorAction)
    if ($script:Fx -and $ClassName -eq $script:Fx.class) { return @($script:Fx.rows | ForEach-Object { [pscustomobject]$_ }) }
    throw 'not available'
}
foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'fixtures') -Filter 'bios-*.json') {
    $script:Fx = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $e = $script:Fx.expect
    Check "$($f.Name): interface detected as $($e.api)" ((Get-BiosApi) -eq $e.api)
    $all = @(Get-BiosOptions $e.api)
    $boot = @($all | Where-Object { $_.Name -match 'SATA|AHCI|Secure ?Boot|Boot ?Mode|Legacy|UEFI|CSM|TPM|Fast ?Boot' })
    Check "$($f.Name): $($e.count_boot_related) boot-related options" ($boot.Count -eq [int]$e.count_boot_related)
    $sata = @($all | Where-Object { $_.Name -match 'SATA' })[0]
    Check "$($f.Name): SATA value and allowed values" ($sata -and $sata.Value -eq $e.sata_value -and (($sata.Allowed -join '/') -eq (@($e.sata_allowed) -join '/')))
}
$script:Fx = $null
Check 'no interface -> none' ($null -eq (Get-BiosApi))
$p = ConvertFrom-LenovoSetting 'WakeOnLAN,Disable'
Check 'Lenovo setting without options still parses' ($p.Name -eq 'WakeOnLAN' -and $p.Value -eq 'Disable' -and $p.Allowed.Count -eq 0)
Check 'Lenovo empty string -> null' ($null -eq (ConvertFrom-LenovoSetting ''))

# ---- BIOS guides
$data = Get-Content (Join-Path $Root 'app\bios-guides.json') -Raw | ConvertFrom-Json
$g = Select-BiosGuide $data 'Dell Inc.' 'Inspiron N5110'
Check 'guide: Dell Inspiron N5110 = model entry, F2, no UEFI' ($g.Source -like 'model*' -and $g.Enter -eq 'F2' -and $g.Uefi -eq $false)
$g = Select-BiosGuide $data 'Dell Inc.' 'Latitude 7420'
Check 'guide: other Dell = maker entry with AHCI steps' ($g.Source -like 'maker*' -and $g.Steps['ahci'] -match 'SATA Operation')
$g = Select-BiosGuide $data 'HP' 'HP ProBook 450 G8'
Check 'guide: HP = F10' ($g.Enter -match 'F10')
$g = Select-BiosGuide $data 'Unknown Maker' 'Model X'
Check 'guide: unknown maker falls back to generic' ($g.Source -eq 'generic' -and $g.Enter -match 'F2')
$g = Select-BiosGuide $null 'Dell' 'x'
Check 'guide: no data file -> empty but valid' ($g.Enter -eq '')

# ---- UEFI boot entries (labels are translated by Windows, so parsing is by position)
$en = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {bootmgr}
                        {0ab5a2a1-1111-2222-3333-444455556666}
timeout                 1

Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume1
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {0ab5a2a1-1111-2222-3333-444455556666}
device                  partition=\Device\HarddiskVolume9
path                    \EFI\BOOT\BOOTX64.EFI
description             UEFI: USB Flash Drive
'@ -split "`r?`n"
$r = ConvertFrom-BcdFirmware $en
Check 'bcd: two entries found' ($r.Entries.Count -eq 2)
Check 'bcd: descriptions read by position' ($r.Entries[1].Description -eq 'UEFI: USB Flash Drive')
Check 'bcd: boot order read' (($r.Order -join ',') -eq '{bootmgr},{0ab5a2a1-1111-2222-3333-444455556666}')
$ar = ($en -replace 'identifier', 'kennung' -replace 'description', 'beschreibung' -replace 'displayorder', 'anzeigereihenfolge')
$r2 = ConvertFrom-BcdFirmware $ar
Check 'bcd: still works when the labels are in another language' ($r2.Entries.Count -eq 2 -and $r2.Entries[1].Description -eq 'UEFI: USB Flash Drive')

# ---- UEFI likelihood and Windows 11 blockers
Check 'uefi: SMBIOS true wins' ((Test-UefiLikely ([pscustomobject]@{ UefiCapable = $true; BiosYear = 2005 })) -eq $true)
Check 'uefi: SMBIOS false wins' ((Test-UefiLikely ([pscustomobject]@{ UefiCapable = $false; BiosYear = 2020 })) -eq $false)
Check 'uefi: unknown flag + old BIOS -> false' ((Test-UefiLikely ([pscustomobject]@{ UefiCapable = $null; BiosYear = 2011 })) -eq $false)
Check 'uefi: unknown flag + recent BIOS -> unknown' ($null -eq (Test-UefiLikely ([pscustomobject]@{ UefiCapable = $null; BiosYear = 2019 })))
$good = [pscustomobject]@{ Firmware = 'UEFI'; SecureBoot = 'on'; TpmSpec = '2.0, 0, 1.38'; RamGB = 16; Disks = @([pscustomobject]@{ System = $true; SizeGB = 512 }); CpuName = 'Intel(R) Core(TM) i7-1165G7' }
Check 'win11: a modern PC has no blockers' ((Get-Win11Blockers $good).Count -eq 0)
$old = [pscustomobject]@{ Firmware = 'BIOS'; SecureBoot = 'unsupported'; TpmSpec = ''; RamGB = 8; Disks = @([pscustomobject]@{ System = $true; SizeGB = 112 }); CpuName = 'Intel(R) Core(TM) i5-2450M CPU @ 2.50GHz' }
Check 'win11: an old PC lists BIOS, TPM and CPU' ((Get-Win11Blockers $old).Count -eq 3)
Check 'cpu generation parsing' ((Get-CpuGeneration 'Intel(R) Core(TM) i5-2450M') -eq 2 -and (Get-CpuGeneration '12th Gen Intel(R) Core(TM) i5-12400') -eq 12 -and (Get-CpuGeneration 'AMD Ryzen 5 3600 6-Core') -eq 3 -and (Get-CpuGeneration 'Intel(R) Core(TM) i7-1165G7') -eq 11 -and (Get-CpuGeneration 'Intel(R) Core(TM) i5-1035G1') -eq 10 -and (Get-CpuGeneration 'Intel(R) Core(TM) i7-8550U') -eq 8 -and (Get-CpuGeneration 'Intel(R) Core(TM) i7-1260P') -eq 12)

if ($script:fails -gt 0) { Write-Output "$script:fails check(s) failed"; exit 1 }
Write-Output 'all BIOS and boot checks passed'
exit 0
