@echo off
REM OdooTool installer launcher for Windows.
REM Runs install.ps1 with the execution policy bypassed for this process only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
