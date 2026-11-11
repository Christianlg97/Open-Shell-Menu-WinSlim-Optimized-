@echo off
cd /d "%~dp0"

call _Version.bat

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\Clean-BuildDirectory.ps1" -RepositoryRoot "%~dp0..\.." -Path "%~dp0Output"
if errorlevel 1 exit /b 1
md Output
md Output\x64
md Output\ARM64

echo -- Compiling

set "MSBuildDir="
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -property installationPath`) do set "MSBuildDir=%%i\MSBuild\Current\Bin\"
if not defined MSBuildDir exit /b 1

REM Restore NuGet packages
"%MSBuildDir%MSBuild.exe" ..\OpenShell.sln /m /t:Restore -p:RestorePackagesConfig=true /verbosity:quiet /nologo
if errorlevel 1 exit /b 1

REM ********* Build x64 solution
echo --- x64
"%MSBuildDir%MSBuild.exe" ..\OpenShell.sln /m /t:Rebuild /p:Configuration="Setup" /p:Platform="x64" /verbosity:quiet /nologo
@if ERRORLEVEL 1 exit /b 1

if "%CS_BUILD_ARM64%"=="0" goto skip_arm64
REM ********* Build ARM64 solution
echo --- ARM64
"%MSBuildDir%MSBuild.exe" ..\OpenShell.sln /m /t:Rebuild /p:Configuration="Setup" /p:Platform="ARM64" /verbosity:quiet /nologo
if ERRORLEVEL 1 exit /b 1

:skip_arm64
REM ********* Build 32-bit solution (must be after 64-bit)
echo --- x86
"%MSBuildDir%MSBuild.exe" ..\OpenShell.sln /m /t:Rebuild /p:Configuration="Setup" /p:Platform="Win32" /verbosity:quiet /nologo
@if ERRORLEVEL 1 exit /b 1


REM ********* Make en-US.dll
cd ..
..\build\bin\Release\Utility.exe makeEN ..\build\bin\Setup\ClassicExplorer32.dll ..\build\bin\Setup\StartMenuDLL.dll ..\build\bin\Setup\ClassicIEDLL_32.dll ..\build\bin\Release\Update.exe
@if ERRORLEVEL 1 exit /b 1

..\build\bin\Release\Utility.exe extract en-US.dll en-US.csv
if errorlevel 1 exit /b 1
move en-US.dll Localization\English > nul
if errorlevel 1 exit /b 1
move en-US.csv Localization\English > nul
if errorlevel 1 exit /b 1

cd Setup


REM ********* Copy binaries

copy /B ..\..\build\bin\Setup\ClassicExplorer32.dll Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\ClassicExplorerSettings.exe Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\ClassicIEDLL_32.dll Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\ClassicIE_32.exe Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\StartMenu.exe Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\StartMenuDLL.dll Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\StartMenuHelper32.dll Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Release\Update.exe Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Release\DesktopToasts.dll Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Release\SetupHelper.exe Output > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Release\Utility.exe Output > nul
if errorlevel 1 exit /b 1

if "%CS_BUILD_ARM64%"=="0" goto skip_arm64_copy
copy /B ..\..\build\bin\SetupARM64\ClassicExplorer64.dll Output\ARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\ClassicIEDLL_64.dll Output\ARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\ClassicIE_64.exe Output\ARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\StartMenu.exe Output\ARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\StartMenuDLL.dll Output\ARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\StartMenuHelper64.dll Output\ARM64 > nul
if errorlevel 1 exit /b 1

:skip_arm64_copy
copy /B ..\..\build\bin\Setup64\ClassicExplorer64.dll Output\x64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\ClassicIEDLL_64.dll Output\x64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\ClassicIE_64.exe Output\x64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\StartMenu.exe Output\x64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\StartMenuDLL.dll Output\x64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\StartMenuHelper64.dll Output\x64 > nul
if errorlevel 1 exit /b 1

copy /B "..\..\build\bin\Skins\Classic Skin.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Full Glass.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Smoked Glass.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Windows Aero.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Windows Basic.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Windows XP Luna.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Windows 8.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Metro.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Classic Skin.skin7" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Windows Aero.skin7" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Windows 8.skin7" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Midnight.skin7" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Metro.skin7" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Metallic.skin7" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Immersive.skin" Output > nul
if errorlevel 1 exit /b 1
copy /B "..\..\build\bin\Skins\Immersive.skin7" Output > nul
if errorlevel 1 exit /b 1

REM ********* Build ADMX
echo --- ADMX
if exist Output\PolicyDefinitions.zip (
  del Output\PolicyDefinitions.zip
)
cd ..\Localization\English
..\..\..\build\bin\Setup\StartMenu.exe -saveadmx en-US
@if ERRORLEVEL 1 exit /b 1
..\..\..\build\bin\Setup\ClassicExplorerSettings.exe -saveadmx en-US
@if ERRORLEVEL 1 exit /b 1
..\..\..\build\bin\Setup\ClassicIE_32.exe -saveadmx en-US
@if ERRORLEVEL 1 exit /b 1
md en-US
copy /B *.adml en-US > nul
if errorlevel 1 exit /b 1
tar -a -c -f ..\..\Setup\Output\PolicyDefinitions.zip *.admx en-US\*.adml PolicyDefinitions.rtf
if errorlevel 1 exit /b 1
rd /Q /S en-US
cd ..\..\Setup

exit /b 0
