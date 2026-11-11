@echo off
if /i "%~1"=="on" goto on
if /i "%~1"=="off" goto off
echo Usage: interaction-trace.cmd on ^| off
exit /b 2
:on
reg add "HKCU\Software\OpenShell\StartMenu\Settings" /v TraceInteractions /t REG_DWORD /d 1 /f
if errorlevel 1 exit /b 1
echo Restart Open-Shell, then reproduce the first click after signing in.
echo Log: %%LOCALAPPDATA%%\OpenShell\InteractionTrace.log
exit /b 0
:off
reg delete "HKCU\Software\OpenShell\StartMenu\Settings" /v TraceInteractions /f
echo Restart Open-Shell to disable tracing.
exit /b 0
