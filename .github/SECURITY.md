# Security policy

Turbo Optimizer runs as administrator, so security reports are taken seriously.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting instead: **Security > Report a vulnerability** on this repository. Include what you found, the steps to reproduce it, and the Windows version.

## What is in scope

- The local web server of the browser version (`TurboOptimizerWeb.ps1`): token and origin checks, anything that lets a web page or another local user trigger an action.
- Commands built from user or file input in the engine.
- Anything that changes the system without the user being asked.

## Design notes

- The browser version listens on `127.0.0.1` only, on a random port, behind a secret token, and accepts action names from a fixed list. It never runs text sent by the page.
- Pull requests that change only `app/TurboUI_strings.json` are merged automatically after validation; the file is read as data. All other changes are reviewed by the owner.
