@echo off
rem Opens the graphical version (no console window). The script asks for administrator rights itself.
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0TurboOptimizerUI.ps1"
