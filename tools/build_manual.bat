@echo off
rem  CsqWatch   Author: yuichi
rem  build_manual.bat -> make app\manual.html from README.md and docs\*.md
rem  Uses only Windows PowerShell 5.1 (no install needed)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Manual.ps1"
pause
