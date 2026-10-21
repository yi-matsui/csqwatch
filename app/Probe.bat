@echo off
rem  CsqWatch   Author: yuichi
rem  Probe.bat            -> check AT commands on the real device
rem  Probe.bat -Mock      -> dry run
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Probe.ps1" %*
pause
