# Changelog

## v12.7

- Live monitor (new "Monitor" page, option 31 in the console): processor, memory, disk and network use with a short history, drives, the processes using the most processor and memory, temperature and battery when available. Read-only. It uses Windows performance classes that have English names, so it works on every Windows language.
- Remove programs completely (Clean and space, option 32 in the console): pick installed programs or Store apps, search and sort by size. The program's own uninstaller runs first (quietly for MSI), then the tool looks for what is left: the install folder and folders with the same name, shortcuts, registry keys with the program's name, and scheduled tasks and orphan services that point into the old folder. You see the list and approve before anything is deleted. Files go to the Recycle Bin; registry keys and tasks are exported first and can be brought back with Revert. Matching is conservative (exact name, versions ignored; publisher folders only when empty), and runtimes such as Visual C++, .NET and WebView2 are protected.
- If a program's uninstaller is broken or missing, the tool asks before cleaning its leftovers anyway.
- Tests: leftover finder on a temporary tree and registry key, uninstall command parsing, monitor sample; 4 more self-test steps. 35 new texts in all 10 languages.

## v12.6

- Fix: the new BIOS actions (boot order, BIOS settings, Dell tool, conversion to GPT) no longer wait for an answer when the tool runs unattended (self-test, scheduled watch, automated checks on a UEFI PC). Added tests for that.

## v12.5

- BIOS guide for this PC: the key to press and the menu steps (AHCI, UEFI, Secure Boot) for your maker and model, from a data file anyone can extend by pull request (merged automatically after validation).
- Better UEFI detection: the BIOS's own "UEFI supported" flag (SMBIOS) replaces the guess from the BIOS date. The conversion to GPT now refuses on PCs whose BIOS says it has no UEFI.
- UEFI boot order (UEFI PCs): start from another entry once, or make an entry first; the previous order can be undone.
- Save a BIOS report to share (no serial numbers) so support for a new model can be added; issue template included.
- Dell: Dell Command | Configure can be installed and used to set AHCI and Secure Boot on supported Dell PCs.
- Tests that run without hardware: recorded samples for Lenovo, HP and Dell interfaces, SMBIOS parsing, boot entries read in any Windows language, guide matching. They found and fixed two bugs: 11th generation and newer Intel CPUs were read as generation 1 (wrong Windows 11 warning), and boot entry descriptions were taken from the wrong line.
- 6 new texts in all 10 languages.

## v12.4

- BIOS settings from Windows now also change options on Dell PCs that have Dell Command | Monitor installed (read and write, using the values the BIOS itself allows). When a Dell PC does not expose its BIOS, the app says what is needed.

## v12.3

- New Disk and boot section: a read-only check (boot mode, Secure Boot, TPM, SATA mode, TRIM, disks with MBR/GPT and SSD/HDD, Windows 11 readiness) with explanations, also part of the Doctor.
- Fixes: turn TRIM on, prepare Windows for AHCI (so the SATA mode can be switched in the BIOS without a boot failure), guided MBR to GPT conversion with Windows' mbr2gpt (checks first, asks to type CONVERT, refuses on PCs that probably have no UEFI).
- BIOS settings from Windows (experimental, Lenovo and HP; Dell read-only) and Restart into BIOS settings (UEFI PCs) or the key to press.
- 14 new texts in all 10 languages.

## v12.2

- Uninstall from inside the app (Safety and tools, or console option 22): offers to undo the changes first, removes the scheduled tasks, closes the app and deletes its own folder and data.
- About screen in the app (sidebar) and in the console (key A): version, author, project link, privacy.
- The install command now asks whether to open the browser app or stay in the console.
- The Dry run switch was removed from the app (the console keeps it: key D or -DryRun).
- Language check: questions the engine asks (close an app, restore point, delete, restart...) are shown in the chosen language, plus the connection message and device type; a note says the log stays in English.
- The user package now carries the page and the translations inside the web script: 3 files in the app folder instead of 5. The source downloads from GitHub leave out tests, tools, docs and screenshots.

## v12.1

- Shorter install command: `irm https://ebnhussein.github.io/TurboOpt/i.txt | iex` (the old raw link still works).
- Tidier repository: the program lives in the app folder; policies are in .github and the changelog in docs, so the top level only has install.ps1, README and LICENSE besides folders.

## v12.0

- One-line install: paste `irm https://ebnhussein.github.io/TurboOpt/i.txt | iex` into PowerShell. It downloads the latest release (SHA-256 checked), keeps your settings and undo history when updating, and opens the app in your browser.
- The classic Windows window version was removed. The browser app (and the console) remain.
- Automatic care, asked on first run and changeable in Safety and tools: Not now, Weekly cleanup, or Watch and fix (a daily check that fixes only safe, reversible problems and sends a notification about serious ones).
- New `-Monitor` mode for the daily watch; `-Browser` opens the app directly.
- 11 new texts in all 10 languages.

## v11.4

- Doctor results: every item can now be ticked (before, advice-only items had a greyed-out box and could not be selected). Clicking anywhere on a row ticks it. New Select all and Clear selection buttons. Fix applies to the items that have a fix; Ignore applies to everything ticked, with a count.

## v11.3

- Redesigned browser version: a Home screen with one main action (Doctor), a health summary, three key numbers and quick actions; clearer sections with icons; a progress panel with a Stop button and a Done summary; details in a collapsible log; a visible banner when Dry run is on.
- Doctor results are now a full page, grouped by severity, with a single primary button (Fix recommended) that stays in view, expandable details per item, and advice-only items collapsed.
- The startup manager uses the same page layout. Windows open with an X, Escape or a click outside.
- 9 new texts translated into all 10 languages.

## v11.2

- Fixed: in the browser version, the Doctor results window could be taller than a small app window, hiding the Fix / Ignore / Close buttons. The list now scrolls and the buttons always show. Added a close button (X), the Escape key and click-outside to close any window.

## v11.1

- Easy download for users: each release now has `TurboOptimizer-v11.1.zip` with one launcher (`Start Turbo Optimizer.bat`), a short `README.txt` and an `app` folder. No repository files to sort through.
- The package is built and attached to the release automatically when a version tag is pushed.

## v11.0

First public release.

- Console menu with seven groups, a framed header with the tool name on every page, and a start screen that offers the browser version, the window version or the console.
- Browser version: local app window with 10 languages and right-to-left support. Local server on `127.0.0.1` with a secret token and origin checks.
- Windows window version with the same languages.
- Doctor: scans Windows Update, drivers, missing DLLs and runtimes, disk health, security settings and the event log, then fixes what you choose.
- Cleaning, space analyzer, disk optimize, debloat, startup manager, services, turbo mode.
- Wi-Fi and Bluetooth fixes, DNS speed test and switch, hosts check, Wi-Fi channel check.
- Reversible Windows Defender off / on / update, security checks.
- Dry-run mode, restore point, undo journal, daily health check and weekly maintenance tasks.
- Translations: English, Arabic, Spanish, French, German, Portuguese, Russian, Chinese (Simplified), Hindi, Turkish.
- CI checks and automatic merge for translation-only pull requests.
