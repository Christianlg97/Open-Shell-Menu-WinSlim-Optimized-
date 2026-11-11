@echo off
setlocal EnableExtensions
title Open-Shell build - CMD
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -File "%~dp0tools\Launch-Build.ps1" %*
set "BUILD_EXIT=%errorlevel%"
if not "%BUILD_EXIT%"=="0" echo La compilacion ha fallado. Revisa el error mostrado arriba.
exit /b %BUILD_EXIT%
