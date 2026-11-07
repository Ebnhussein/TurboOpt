# Turbo Optimizer

A Windows 10/11 cleanup, repair and tune-up tool written in PowerShell. It finds problems, explains them, and fixes what you choose. Every change is recorded so you can undo it.

![Browser version](docs/ui-home.png)

| Console menu | Start screen |
|---|---|
| ![Console menu](docs/console-menu.png) | ![Start screen](docs/console-start.png) |

The Doctor in Arabic (right-to-left layout, 10 languages in total):

![Doctor results in Arabic](docs/ui-doctor-ar.png)

Three ways to use it, all running the same engine:

| Launcher | What you get |
|---|---|
| `TurboOptimizer.bat` | Console with a numbered menu. On start it offers to open one of the graphical versions. |
| `TurboOptimizerWeb.bat` | Browser version: a local app window (Edge, or Chrome if Edge is missing). 10 languages, right-to-left support. |
| `TurboOptimizerUI.bat` | Classic Windows (WinForms) window. Same languages. |

## What it does

- **Doctor**: scans Windows Update, drivers, missing DLLs and runtimes, disk health, security settings and the event log, then fixes the items you pick.
- **Clean and space**: temp files, update and browser caches, a space analyzer, disk optimize (TRIM or defrag), debloat of preinstalled apps.
- **Speed**: performance power plan, startup manager (turn off or delay), optional services.
- **Update and repair**: app updates through winget, SFC and DISM, driver backup and restore.
- **Network**: Wi-Fi and Bluetooth hang fixes, DNS speed test and switch, hosts file check, Wi-Fi channel check.
- **Security**: firewall, SMBv1, Remote Desktop, UAC, and a reversible Defender off / on / update.
- **Safety**: restore point, an undo journal for every change, a daily health check and weekly maintenance as scheduled tasks.

It asks before closing any program. If you say no, that step is skipped.

## Requirements

- Windows 10 version 1809 or newer, or Windows 11
- Windows PowerShell 5.1 (included with Windows)
- Administrator rights (the tool asks for them itself)
- For the browser version: Microsoft Edge or Google Chrome

## Quick start

1. Download or clone this repository: `git clone https://github.com/Ebnhussein/TurboOpt.git`
2. Double-click `TurboOptimizer.bat`.
3. Pick the browser version, the window version, or stay in the console.

Tick **Dry run** first to see what would happen without changing anything.

## Safety

- Dry run mode describes every action and changes nothing.
- A restore point can be created before bigger changes.
- Changes are written to `turbo_undo.json`; the Revert option reverses them.
- Defender can be turned off and back on. Windows Tamper Protection may block this; the tool tells you when it does.
- The browser version listens on `127.0.0.1` only, on a random port, behind a secret token, and the page can only request actions by name.

Read `config.ini` to see which cleanups and apps are on by default, and change them to suit you. Use this tool on your own machine and review what it offers before accepting.

## Languages

English, Arabic, Spanish, French, German, Portuguese, Russian, Chinese (Simplified), Hindi and Turkish. To add one, copy a block in `TurboUI_strings.json`, translate the values and set `_name` and `_rtl`. The console and the detailed scan results are in English.

## Files

| File | Purpose |
|---|---|
| `TurboOptimizer.ps1` | The engine and the console menu |
| `TurboOptimizerWeb.ps1`, `TurboWeb.html` | Browser version (local server and page) |
| `TurboOptimizerUI.ps1` | Windows window version |
| `TurboUI_strings.json` | Translations |
| `config.ini` | Lists and options |

Files created at run time (`turbo_log.txt`, `turbo_errors.log`, `turbo_undo.json`, `turbo_acks.json`, health reports) are listed in `.gitignore`.

## Self-test

```powershell
powershell -ExecutionPolicy Bypass -File .\TurboOptimizer.ps1 -SelfTest
powershell -ExecutionPolicy Bypass -File .\TurboOptimizerWeb.ps1 -Test -TestAll
```

Both run in dry-run mode.

## نبذة بالعربي

أداة لتنظيف وإصلاح وتسريع ويندوز. بتفحص الجهاز وتشرح المشاكل وتصلّح اللي تختاره، وكل تغيير بيتسجل وتقدر ترجع فيه. شغّل `TurboOptimizer.bat` واختار: نسخة المتصفح، أو نافذة ويندوز، أو الكونسول. جرّب وضع "تجربة فقط" الأول عشان تشوف إيه اللي هيتعمل من غير ما يتغير حاجة.

## Contributing

Translations: edit only `TurboUI_strings.json` and open a pull request. If the automatic check passes, it is merged without waiting for anyone. Code changes are checked by CI and reviewed by the owner, because this tool runs as administrator. Details in [CONTRIBUTING.md](CONTRIBUTING.md).

## Author

Made by [Ebnhussein](https://github.com/Ebnhussein). Project page: https://github.com/Ebnhussein/TurboOpt

## License

MIT, see `LICENSE`.
