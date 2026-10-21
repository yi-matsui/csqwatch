@echo off
rem  CsqWatch   Author: yuichi
rem  Mock mode (no device needed): double-click to try the dashboard
cd /d "%~dp0"
rem  The dashboard is opened by Monitor.ps1 in a separate browser (see Browser.ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Monitor.ps1" -Mock
rem  exit code 3 = Monitor is already running; the dashboard was brought to front
if "%ERRORLEVEL%"=="3" exit /b 0
pause
