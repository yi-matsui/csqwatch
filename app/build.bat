@echo off
rem  CsqWatch   Author: yuichi
rem  AtIo.cs -> AtIo.exe  (uses the csc.exe bundled with Windows .NET Framework 4.x)
cd /d "%~dp0"
set CSC=%windir%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" set CSC=%windir%\Microsoft.NET\Framework\v4.0.30319\csc.exe
"%CSC%" /nologo /target:exe /out:AtIo.exe AtIo.cs
if errorlevel 1 (echo BUILD FAILED) else (echo BUILD OK: AtIo.exe)
pause
