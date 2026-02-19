@echo off
title Windows Turbo Optimizer Pro v9.0
setlocal enabledelayedexpansion

:: 1. طلب صلاحيات المسؤول
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    powershell -Command "Start-Process '%~0' -Verb RunAs"
    exit /B
)

:: 2. صوت ترحيبي
powershell -Command "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('Welcome. I am ready to optimize your system.')" >nul 2>&1

:: 3. إعداد ملف الـ Log
set LOGFILE=%~dp0optimizer_log.txt
echo [!DATE! !TIME!] - Script Started > "%LOGFILE%"

:MENU
cls
color 0B
echo ===========================================================================
echo    WINDOWS TURBO OPTIMIZER - SYSTEM DASHBOARD
echo ===========================================================================

:: جلب تفاصيل الجهاز بدقة
for /f "delims=" %%a in ('powershell -command "(Get-CimInstance Win32_Processor).Name"') do set CPU=%%a
for /f "delims=" %%a in ('powershell -command "[Math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB)"') do set RAM_GB=%%a

echo  [+] CPU:  %CPU%
echo  [+] RAM:  %RAM_GB% GB

echo  [+] GPU(s):
powershell -Command "Get-CimInstance Win32_VideoController | ForEach-Object { Write-Host '      - ' $_.Name -ForegroundColor Cyan }"
echo  [+] Disk(s):
powershell -Command "Get-CimInstance Win32_DiskDrive | ForEach-Object { Write-Host '      - ' $_.Model ' (' [Math]::Round($_.Size / 1GB) ' GB)' -ForegroundColor Cyan }"

echo ===========================================================================
echo  1. [SAFE] Create System Restore Point   5. [DEEP] Repair System Files
echo  2. [FAST] Quick Clean (RAM + Temp)      6. [CLEAN] System Debloater
echo  3. [CORE] CPU Turbo Mode                7. [LOGS] View Action History
echo  4. [APPS] Update All Software           8. [FIRE] ALL IN ONE OPTIMIZE
echo  0. EXIT
echo ===========================================================================
set /p opt=" >> Select Action: "

if "%opt%"=="1" goto CREATE_RESTORE
if "%opt%"=="2" goto WARN_CLEAN
if "%opt%"=="3" goto WARN_TURBO
if "%opt%"=="4" goto WARN_UPDATE
if "%opt%"=="5" goto WARN_REPAIR
if "%opt%"=="6" goto WARN_DEBLOAT
if "%opt%"=="7" start notepad "%LOGFILE%" & goto MENU
if "%opt%"=="8" goto WARN_ALL
if "%opt%"=="0" exit
goto MENU

:: --- قسم التحذيرات والشرح ---

:WARN_CLEAN
cls
color 0E
echo [ WARNING: QUICK CLEAN ]
echo ---------------------------------------------------------
echo - Will flush Standby Memory (RAM).
echo - Will delete ALL files in Temp folders.
echo - Will clear DNS Cache (Internet refresh).
set /p c="Proceed with Cleaning? (Y/N): "
if /i "%c%"=="Y" goto QUICK_CLEAN_TASK
goto MENU

:WARN_TURBO
cls
color 0D
echo [ WARNING: CPU TURBO ]
echo ---------------------------------------------------------
echo - Will enable 'Ultimate Performance' Power Plan.
echo - Will limit Windows Defender CPU usage to 25%%.
echo - Will PERMANENTLY disable 'SysMain' (Superfetch).
set /p c="Proceed with Turbo Mode? (Y/N): "
if /i "%c%"=="Y" goto TURBO_TASK
goto MENU

:WARN_UPDATE
cls
color 0A
echo [ WARNING: SOFTWARE UPDATE ]
echo ---------------------------------------------------------
echo - Will check and update ALL installed apps via Winget.
echo - Requires an active internet connection.
set /p c="Start Update? (Y/N): "
if /i "%c%"=="Y" goto UPDATE_TASK
goto MENU

:WARN_REPAIR
cls
color 0F
echo [ WARNING: SYSTEM REPAIR ]
echo ---------------------------------------------------------
echo - Will run SFC Scan and DISM Image Repair.
echo - This process might take 10-20 minutes.
set /p c="Start Repair? (Y/N): "
if /i "%c%"=="Y" goto REPAIR_TASK
goto MENU

:WARN_DEBLOAT
cls
color 0C
echo [ WARNING: SYSTEM DEBLOAT ]
echo ---------------------------------------------------------
echo - Will REMOVE: Skype, News, Weather, 3D Builder, Cortana.
echo - Will REMOVE: Microsoft Office Hub and Mail/Calendar.
set /p c="Are you sure you want to delete these apps? (Y/N): "
if /i "%c%"=="Y" goto DEBLOAT_TASK
goto MENU

:WARN_ALL
cls
color 0B
echo [ WARNING: ALL-IN-ONE OPTIMIZATION ]
echo ---------------------------------------------------------
echo This will execute: Clean + Turbo + Update + Debloat.
echo Your system may lag slightly during the process.
set /p c="Ready for full optimization? (Y/N): "
if /i "%c%"=="Y" goto ALL_IN_ONE
goto MENU

:: --- تنفيذ المهام ---

:ALL_IN_ONE
cls
powershell -Command "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('Starting full optimization sequence.')"
call :QUICK_CLEAN_TASK
call :TURBO_TASK
call :UPDATE_TASK
call :DEBLOAT_TASK
echo.
echo [!] ALL-IN-ONE COMPLETE.
powershell -Command "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak('Process finished.')"
pause
goto MENU

:CREATE_RESTORE
cls
echo [+] Creating Restore Point...
powershell -Command "Enable-ComputerRestore -Drive 'C:\'; Checkpoint-Computer -Description 'TurboOpt_v9' -RestorePointType 'MODIFY_SETTINGS'"
echo [%DATE% %TIME%] Restore Point Created >> "%LOGFILE%"
pause & goto MENU

:QUICK_CLEAN_TASK
echo [+] Cleaning Files...
powershell -Command "Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue; [System.GC]::Collect(); ipconfig /flushdns"
echo [%DATE% %TIME%] Quick Clean Done >> "%LOGFILE%"
if "%opt%"=="2" pause & goto MENU
goto :eof

:TURBO_TASK
echo [+] Activating Turbo...
powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 >nul
powershell -Command "Set-MpPreference -ScanAvgCPULoadFactor 25; Stop-Service -Name 'SysMain' -Force -ErrorAction SilentlyContinue; Set-Service -Name 'SysMain' -StartupType Disabled"
echo [%DATE% %TIME%] Turbo Mode Activated >> "%LOGFILE%"
if "%opt%"=="3" pause & goto MENU
goto :eof

:UPDATE_TASK
echo [+] Updating Apps...
winget upgrade --all --accept-package-agreements
if "%opt%"=="4" pause & goto MENU
goto :eof

:REPAIR_TASK
echo [+] Running SFC and DISM...
sfc /scannow
Dism /Online /Cleanup-Image /RestoreHealth
pause & goto MENU

:DEBLOAT_TASK
echo [+] Removing Apps one by one...
powershell -Command "$apps = @('*3dbuilder*', '*skypeapp*', '*officehub*', '*bingweather*', '*bingnews*', '*communicationsapps*', '*zunevideo*', '*cortana*'); foreach ($app in $apps) { Get-AppxPackage $app | Remove-AppxPackage -ErrorAction SilentlyContinue }"
echo [%DATE% %TIME%] System Debloated >> "%LOGFILE%"
if "%opt%"=="6" pause & goto MENU
goto :eof

