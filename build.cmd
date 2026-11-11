@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Build.ps1" %*
set "BUILD_EXIT=%errorlevel%"
if not "%BUILD_EXIT%"=="0" echo Build failed. Review the error above.
exit /b %BUILD_EXIT%
