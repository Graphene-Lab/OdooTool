@echo off
REM OdooTool uninstaller launcher for Windows.
REM Works even when only this .bat was downloaded: it fetches uninstall.ps1 by itself.
REM The window stays open at the end so the user can read the messages.
REM
REM INSTALLER CONTRACT - see INSTALLER-CONTRACT.md. The deletion is guarded by a yes/no question
REM and by the phrase DESTROY ALL typed in capitals: it removes the database, and nothing here
REM makes a backup.
REM
REM CROSS-PLATFORM PARITY - this file and installer\uninstall.ps1 are the Windows half of ONE
REM uninstaller. Every substantial change here must be made in installer/uninstall.sh too.
setlocal
title OdooTool uninstaller

set "PS1=%~dp0uninstall.ps1"
if exist "%PS1%" goto run

echo Downloading the uninstaller script...
set "PS1=%TEMP%\odootool-uninstall.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest 'https://raw.githubusercontent.com/Graphene-Lab/OdooTool/main/installer/uninstall.ps1' -OutFile \"$env:TEMP\odootool-uninstall.ps1\" -UseBasicParsing"
if not exist "%TEMP%\odootool-uninstall.ps1" (
    echo.
    echo Could not download the uninstaller script. Check the internet connection.
    echo Press any key to close this window.
    pause >nul
    exit /b 1
)

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
echo The uninstaller has finished. Review the messages above.
echo Press any key to close this window.
pause >nul
