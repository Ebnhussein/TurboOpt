# Changelog

## v12.0

- One-line install: paste `irm https://raw.githubusercontent.com/Ebnhussein/TurboOpt/main/install.ps1 | iex` into PowerShell. It downloads the latest release (SHA-256 checked), keeps your settings and undo history when updating, and opens the app in your browser.
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
