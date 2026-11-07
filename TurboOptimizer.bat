@echo off
rem Launcher for TurboOptimizer.ps1 (bypasses the execution policy; the script asks for admin itself).
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TurboOptimizer.ps1" %*
if errorlevel 1 pause
