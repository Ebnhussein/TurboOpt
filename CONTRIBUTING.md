# Contributing

## Translations: merged automatically

Add a language or fix a translation by editing `TurboUI_strings.json` only:

1. Copy an existing language block (for example `de`), change the code, and translate every value.
2. Set `_name` (the name shown in the language list) and `_rtl` (`1` for right-to-left languages, otherwise `0`).
3. Keep the placeholders such as `{0}` and `{1}` exactly as in English, and do not use `<` or `>`.
4. Open a pull request that changes **only** that file.

A workflow checks the file with `tests/validate-strings.ps1`. If it passes, the pull request is merged automatically. If not, the workflow log lists what to fix. You can run the same check yourself:

```powershell
.\tests\validate-strings.ps1 -Candidate .\TurboUI_strings.json
```

## Code changes: reviewed by the owner

This tool runs as administrator on people's PCs, so a pull request that changes any other file is never merged automatically. CI runs on it (scripts parse, files stay ASCII, dry-run self-test) and the owner reviews it.

Before opening one, run the self-tests from the README. They run in dry-run mode and change nothing.
