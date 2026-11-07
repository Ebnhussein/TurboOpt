@echo off
rem Opens the browser version (an app window, no console). The script asks for administrator rights itself.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TurboOptimizerWeb.ps1"
