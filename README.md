# Turbo Optimizer: free Windows 10/11 optimizer, PC cleaner and repair tool

[![CI](https://github.com/Ebnhussein/TurboOpt/actions/workflows/ci.yml/badge.svg)](https://github.com/Ebnhussein/TurboOpt/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Languages](https://img.shields.io/badge/languages-10-brightgreen)

**English** | [العربية](docs/README.ar.md) | [Español](docs/README.es.md) | [Français](docs/README.fr.md) | [Deutsch](docs/README.de.md) | [Português](docs/README.pt.md) | [Русский](docs/README.ru.md) | [简体中文](docs/README.zh.md) | [हिन्दी](docs/README.hi.md) | [Türkçe](docs/README.tr.md)

Turbo Optimizer is an open-source **Windows optimizer, system cleaner and repair tool** written in PowerShell. It scans your PC, explains what is wrong, and fixes only what you choose: slow startup, full C: drive, Windows Update errors, missing DLL files, driver problems, Wi-Fi and Bluetooth that keep dropping. Every change is recorded, so you can **undo it**.

No installer, no ads, no telemetry. Paste one line into PowerShell: it downloads, opens a modern app window in your browser, and asks what you want.

```powershell
irm https://ebnhussein.github.io/TurboOpt/i.txt | iex
```

![Turbo Optimizer browser version](docs/ui-home.png)

| Console menu | Start screen |
|---|---|
| ![Console menu](docs/console-menu.png) | ![Start screen](docs/console-start.png) |

The Doctor in Arabic (right-to-left layout, 10 languages in total):

![Doctor results in Arabic](docs/ui-doctor-ar.png)

## Features

- **Doctor: find and fix Windows problems.** Scans Windows Update, drivers, missing DLLs and runtimes, disk health, security settings and the event log, then fixes the items you pick.
- **PC cleaner.** Temp files, Windows Update cache, browser caches, a disk space analyzer, TRIM for SSD and defrag for hard drives, and removal of preinstalled apps (debloat).
- **Remove programs completely.** Lists your installed programs and Store apps, runs each one's own uninstaller, then finds what it left behind (folders, registry keys, scheduled tasks, shortcuts) and shows the list before deleting anything. Files go to the Recycle Bin; registry keys and tasks are saved first, so "Revert" brings them back. Runtimes such as Visual C++ and .NET are protected.
- **Live monitor.** Processor, memory, disk and network use with a short history, drives, the processes using the most processor and memory (with an End button, never for Windows' own processes), temperature and battery when Windows reports them. Advice appears when something is wrong, and stays as an alert if it lasts 30 seconds. Read-only unless you end a program; nothing leaves the PC.
- **Performance history.** Optional: a small hidden task writes one line every 5 minutes (kept 14 days, on your PC only) so you can see why the PC was slow earlier and which program was busiest.
- **Device summary.** One health score out of 100 built from memory, processor, free space, startup programs, the last health check, heat and restarts, with the advice behind it and a button for each fix.
- **Speed up Windows.** Performance power plan, startup manager (turn off or delay programs), optional services.
- **Disk and boot.** Explains MBR vs GPT and BIOS vs UEFI for your PC, checks AHCI mode, TRIM and Windows 11 readiness, prepares Windows for AHCI, converts MBR to GPT with Windows' own tool (refuses on PCs that cannot start from UEFI), shows the BIOS key and menu steps for your maker and model, manages the UEFI boot order, and can read and change some BIOS options from Windows on Lenovo, HP and Dell PCs that expose them (experimental; Dell needs Dell Command | Monitor or Dell Command | Configure). It cannot change the BIOS on other PCs: Windows has no standard way to do that, so it tells you exactly what to do in the BIOS menu instead.
- **Update and repair.** App updates through winget, SFC and DISM, driver backup and restore.
- **Network fixes.** Wi-Fi and Bluetooth hang fixes, DNS speed test and switch, hosts file check, Wi-Fi channel check.
- **Security checks.** Firewall, SMBv1, Remote Desktop, UAC, and a reversible Windows Defender off / on / update.
- **Safety first.** Asks before risky steps, restore point, an undo journal for every change, a console dry-run mode (press D) that changes nothing, and an Uninstall button inside the app.
- **Automatic care (optional).** Weekly cleanup, or a daily watch that fixes only safe, reversible problems (temp files, clock sync, DNS cache, Defender definitions, stopped services) and sends a notification when something serious needs you.

It asks before closing any program. If you say no, that step is skipped.

## How it works

1. Open **PowerShell** (Start menu, type `powershell`) and paste the line above.
2. It downloads the latest release (checksum verified), keeps it in `%LOCALAPPDATA%\TurboOptimizer`, and opens the app in your browser (Edge, or Chrome if Edge is missing). Windows asks once for administrator rights.
3. On the first run it asks whether you want **automatic care**: *Not now*, *Weekly cleanup*, or *Watch and fix* (a daily check that fixes only safe problems and notifies you about the rest). You can change it any time in Safety and tools.

When it starts it asks whether you want the browser app or the console. Run the same line again to update; your settings and undo history are kept. To remove everything, use Uninstall inside the app (Safety and tools) or console option 22. Prefer an offline copy? Download `TurboOptimizer-v….zip` from [Releases](https://github.com/Ebnhussein/TurboOpt/releases/latest), unzip it, and double-click `Start Turbo Optimizer.bat` (a console menu is also available there).

## Requirements

- Windows 10 version 1809 or newer, or Windows 11
- Windows PowerShell 5.1 (included with Windows)
- Administrator rights (the tool asks for them itself)
- Microsoft Edge or Google Chrome (for the app window)

## Quick start

```powershell
irm https://ebnhussein.github.io/TurboOpt/i.txt | iex
```

Developers can clone the repository instead: `git clone https://github.com/Ebnhussein/TurboOpt.git` and run `app\TurboOptimizer.bat`.

## Common problems it helps with

| You search for | Where to look |
|---|---|
| How to clean temp files and free disk space on Windows 10 | Clean files, Free up space |
| Windows PC slow after boot, too many startup programs | Startup programs |
| Bluetooth headphones connected but no sound on Windows | Bluetooth no-sound fix, Bluetooth and audio reset |
| Wi-Fi keeps disconnecting or hangs on Windows 10/11 | Wi-Fi quick reset, Stop power saving, Deep network reset |
| Windows Update stuck, failed or waiting | Doctor, Update and repair |
| Missing DLL error (d3dx9, xinput, MSVCP, VCRUNTIME) | Doctor downloads the runtime from Microsoft |
| Repair corrupted Windows system files (SFC and DISM) | Repair system files |
| Remove bloatware and preinstalled apps from Windows | Remove preinstalled apps |
| Turn Windows Defender off and back on, reversibly | Defender: off / on / update |
| Back up and restore drivers before reinstalling Windows | Back up drivers, Restore drivers |
| Fastest DNS server for my connection | DNS speed test, Switch DNS |
| Check disk errors, NTFS problems, SSD or HDD health | Doctor, Optimize drives |

## Safety

- In the console, Dry run (press D, or start with `-DryRun`) describes every action and changes nothing.
- A restore point can be created before bigger changes.
- Changes are written to `turbo_undo.json`; the Revert option reverses them.
- Defender can be turned off and back on. Windows Tamper Protection may block this; the tool tells you when it does.
- The browser version listens on `127.0.0.1` only, on a random port, behind a secret token, and the page can only request actions by name.

Read `app/config.ini` to see which cleanups and apps are on by default, and change them to suit you. Use this tool on your own machine and review what it offers before accepting. See [SECURITY.md](.github/SECURITY.md) to report a vulnerability.

## Languages

English, Arabic, Spanish, French, German, Portuguese, Russian, Chinese (Simplified), Hindi and Turkish. To add one, copy a block in `app/TurboUI_strings.json`, translate the values and set `_name` and `_rtl`. The console and the detailed scan results are in English.

## FAQ

**Is it safe?** It asks before risky steps, creates restore points on request, and records every change in an undo journal, and can remove itself completely (Safety and tools, Uninstall). You can read the whole source: it is plain PowerShell.

**Does it speed up my PC?** It removes junk, trims startup, and fixes configuration problems. How much that helps depends on your machine. It does not overclock or tweak hidden settings.

**Does it send data anywhere?** No telemetry. It only goes online when you ask it to: winget updates, Windows Update, downloading a missing runtime from Microsoft, DNS tests.

**Does it work on Windows 7, 8 or Linux?** No. Windows 10 (1809+) and Windows 11 only.

**Can I run it without a graphical window?** Yes. `app\TurboOptimizer.bat` stays in the console and also supports unattended mode for scheduled tasks.

## Files

| Path | Purpose |
|---|---|
| `install.ps1` | One-line installer |
| `app/` | What gets installed: the engine (`TurboOptimizer.ps1`), the browser app (`TurboOptimizerWeb.ps1`, `TurboWeb.html`), translations (`TurboUI_strings.json`) and `config.ini` |
| `docs/` | Translated READMEs, screenshots, changelog |
| `tests/`, `tools/`, `.github/` | Checks, the release packager, workflows and project policies |

Files created at run time (`turbo_log.txt`, `turbo_errors.log`, `turbo_undo.json`, `turbo_acks.json`, `turbo_prefs.json`, health reports) are listed in `.gitignore`.

## Self-test

```powershell
powershell -ExecutionPolicy Bypass -File .\app\TurboOptimizer.ps1 -SelfTest
powershell -ExecutionPolicy Bypass -File .\app\TurboOptimizerWeb.ps1 -Test -TestAll
powershell -ExecutionPolicy Bypass -File .\tests\test-programs.ps1
```

```powershell
powershell -ExecutionPolicy Bypass -File .\app\TurboOptimizer.ps1 -Monitor -DryRun
```

All run in dry-run mode.

## Contributing

Translations (`app/TurboUI_strings.json`) and BIOS guides for your PC model (`app/bios-guides.json`): edit only those files and open a pull request. If the automatic check passes, it is merged without waiting for anyone. Code changes are checked by CI and reviewed by the owner, because this tool runs as administrator. Details in [CONTRIBUTING.md](.github/CONTRIBUTING.md).

If this tool helped you, a star on the repository helps others find it.

## Author

Made by [Ebnhussein](https://github.com/Ebnhussein). Project page: https://github.com/Ebnhussein/TurboOpt

## License

MIT, see `LICENSE`.
