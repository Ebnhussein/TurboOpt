# Contributing

## Translations: merged automatically

Add a language or fix a translation by editing `app/TurboUI_strings.json` only:

1. Copy an existing language block (for example `de`), change the code, and translate every value.
2. Set `_name` (the name shown in the language list) and `_rtl` (`1` for right-to-left languages, otherwise `0`).
3. Keep the placeholders such as `{0}` and `{1}` exactly as in English, and do not use `<` or `>`.
4. Open a pull request that changes **only** that file.

A workflow checks the file with `tests/validate-strings.ps1`. If it passes, the pull request is merged automatically. If not, the workflow log lists what to fix. You can run the same check yourself:

```powershell
.\tests\validate-strings.ps1 -Candidate .\app\TurboUI_strings.json
```

## BIOS guides: merged automatically

`app/bios-guides.json` holds the key to press and the menu steps per maker and model. To add or fix a model, copy an entry under `models`:

```json
{ "maker": "Dell", "model": "Inspiron N5110", "enter": "F2", "boot_menu": "F12", "uefi": false, "verified": true,
  "steps": { "ahci": "Advanced > SATA Operation > AHCI" }, "note": "Legacy BIOS only." }
```

`maker` and `model` are short regular expressions matched against what Windows reports (Win32_ComputerSystem). Allowed steps: `ahci`, `uefi`, `secureboot`, `legacy`. Set `verified` to true only if you checked it on that PC. Plain text only: no links, no `<`.

Check it yourself with `.\tests\validate-guides.ps1 -Candidate .\app\bios-guides.json`. A pull request that changes only the translations and/or this file is merged automatically when the check passes.

To help support a new PC for BIOS changes from Windows (Lenovo, HP, Dell), run Disk and boot > "Save a BIOS report to share" and open a "BIOS report" issue with the file. Add a fixture in `tests/fixtures` to cover a new model.

## Code changes: reviewed by the owner

This tool runs as administrator on people's PCs, so a pull request that changes any other file is never merged automatically. CI runs on it (scripts parse, files stay ASCII, dry-run self-test) and the owner reviews it.

Before opening one, run the self-tests from the README. They run in dry-run mode and change nothing.
