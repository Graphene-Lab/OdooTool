@echo off
REM OdooTool installer launcher for Windows.
REM Works even when only this .bat was downloaded: it fetches install.ps1 by itself.
REM The window stays open at the end so the user can read the messages.
REM
REM INSTALLER CONTRACT - see INSTALLER-CONTRACT.md. The "AI Odoo" icon created by the
REM installer must start Odoo, give AgentBridge a visible terminal window, and open Odoo at
REM http://localhost:8069 in the default browser. The assistant's office chat on 5290 is a
REM second entrance and is never opened automatically.
REM
REM CROSS-PLATFORM PARITY - this file and installer\install.ps1 are the Windows half of ONE
REM installer. Every substantial change here must be made in installer/install.sh too: the
REM Linux user must get the same behaviour, the same questions and the same final state.
REM Do not "simplify" one side on its own.
setlocal
title OdooTool installer

set "PS1=%~dp0install.ps1"
if exist "%PS1%" goto run

echo Downloading the installer script...
set "PS1=%TEMP%\odootool-install.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest 'https://raw.githubusercontent.com/Graphene-Lab/OdooTool/main/installer/install.ps1' -OutFile \"$env:TEMP\odootool-install.ps1\" -UseBasicParsing"
if not exist "%TEMP%\odootool-install.ps1" (
    echo.
    echo Could not download the installer script. Check the internet connection.
    echo Press any key to close this window.
    pause >nul
    exit /b 1
)

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

echo.
echo The installer has finished. Review the messages above.
echo Press any key to close this window.
pause >nul
