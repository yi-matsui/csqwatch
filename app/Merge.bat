@echo off
rem  CsqWatch   Author: yuichi
rem  Merge.bat                      -> choose a folder of past data and merge it into $LogDir
rem  Merge.bat "D:\old\logs" ...   -> merge the listed folders
rem  Stop Monitor first.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Merge.ps1" %*
pause
