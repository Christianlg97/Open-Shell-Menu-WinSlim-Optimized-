@echo off
cd /d "%~dp0"
set "CS_BUILD_STEP=Preparar directorios de compilacion"

call _Version.bat

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\Clean-BuildDirectory.ps1" -RepositoryRoot "%~dp0..\.." -Path "%~dp0Output"
if errorlevel 1 goto build_failed
md Output
md Output\x64
md Output\ARM64

echo -- Compiling

set "MSBuildExe="
if defined CS_MSBUILD_PATH (
	if not exist "%CS_MSBUILD_PATH%" (
		echo MSBuild not found at CS_MSBUILD_PATH: "%CS_MSBUILD_PATH%"
		exit /b 1
	)
	set "MSBuildExe=%CS_MSBUILD_PATH%"
) else (
	for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -version "[17.0,18.0)" -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "MSBuildExe=%%i\MSBuild\Current\Bin\MSBuild.exe"
)
if not defined MSBuildExe exit /b 1
if not exist "%MSBuildExe%" exit /b 1
REM Build.ps1 -Incremental sets Build; anything else keeps the original full Rebuild.
if /i not "%CS_MSBUILD_TARGET%"=="Build" set "CS_MSBUILD_TARGET=Rebuild"

REM Restore NuGet packages
set "CS_BUILD_STEP=Restaurar paquetes NuGet"
echo --- %CS_BUILD_STEP%
"%MSBuildExe%" ..\OpenShell.sln /m /t:Restore -p:RestorePackagesConfig=true /verbosity:quiet /nologo
if errorlevel 1 goto build_failed

REM ********* Build x64 solution
set "CS_BUILD_STEP=Compilar x64"
echo --- x64
"%MSBuildExe%" ..\OpenShell.sln /m /t:%CS_MSBUILD_TARGET% /p:Configuration="Setup" /p:Platform="x64" /verbosity:quiet /nologo
@if ERRORLEVEL 1 goto build_failed

if "%CS_BUILD_ARM64%"=="0" goto skip_arm64
REM ********* Build ARM64 solution
set "CS_BUILD_STEP=Compilar ARM64 y ARM64EC"
echo --- ARM64
"%MSBuildExe%" ..\OpenShell.sln /m /t:%CS_MSBUILD_TARGET% /p:Configuration="Setup" /p:Platform="ARM64" /verbosity:quiet /nologo
if ERRORLEVEL 1 goto build_failed

:skip_arm64
REM ********* Build 32-bit solution (must be after 64-bit)
set "CS_BUILD_STEP=Compilar x86"
echo --- x86
"%MSBuildExe%" ..\OpenShell.sln /m /t:%CS_MSBUILD_TARGET% /p:Configuration="Setup" /p:Platform="Win32" /verbosity:quiet /nologo
@if ERRORLEVEL 1 goto build_failed


REM ********* Make en-US.dll
set "CS_BUILD_STEP=Generar en-US.dll"
echo --- %CS_BUILD_STEP%
cd ..
..\build\bin\Release\Utility.exe makeEN ..\build\bin\Setup\ClassicExplorer32.dll ..\build\bin\Setup\StartMenuDLL.dll ..\build\bin\Setup\ClassicIEDLL_32.dll ..\build\bin\Release\Update.exe
@if ERRORLEVEL 1 goto build_failed

set "CS_BUILD_STEP=Exportar en-US.csv con Utility.exe"
echo --- %CS_BUILD_STEP%
..\build\bin\Release\Utility.exe extract en-US.dll en-US.csv
if errorlevel 1 goto build_failed
set "CS_BUILD_STEP=Publicar los recursos de idioma ingles"
echo --- %CS_BUILD_STEP%
move /Y en-US.dll Localization\English > nul
if errorlevel 1 goto build_failed
move /Y en-US.csv Localization\English > nul
if errorlevel 1 goto build_failed

cd Setup


REM ********* Copy binaries
set "CS_BUILD_STEP=Copiar los binarios del instalador"
echo --- %CS_BUILD_STEP%

copy /B ..\..\build\bin\Setup\ClassicExplorer32.dll Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup\ClassicExplorerSettings.exe Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup\ClassicIEDLL_32.dll Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup\ClassicIE_32.exe Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup\StartMenu.exe Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup\StartMenuDLL.dll Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup\StartMenuHelper32.dll Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Release\Update.exe Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Release\DesktopToasts.dll Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Release\SetupHelper.exe Output > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Release\Utility.exe Output > nul
if errorlevel 1 goto build_failed

if "%CS_BUILD_ARM64%"=="0" goto skip_arm64_copy
copy /B ..\..\build\bin\SetupARM64\ClassicExplorer64.dll Output\ARM64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\SetupARM64\ClassicIEDLL_64.dll Output\ARM64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\SetupARM64\ClassicIE_64.exe Output\ARM64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\SetupARM64\StartMenu.exe Output\ARM64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\SetupARM64\StartMenuDLL.dll Output\ARM64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\SetupARM64\StartMenuHelper64.dll Output\ARM64 > nul
if errorlevel 1 goto build_failed

:skip_arm64_copy
copy /B ..\..\build\bin\Setup64\ClassicExplorer64.dll Output\x64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup64\ClassicIEDLL_64.dll Output\x64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup64\ClassicIE_64.exe Output\x64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup64\StartMenu.exe Output\x64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup64\StartMenuDLL.dll Output\x64 > nul
if errorlevel 1 goto build_failed
copy /B ..\..\build\bin\Setup64\StartMenuHelper64.dll Output\x64 > nul
if errorlevel 1 goto build_failed

set "CS_BUILD_STEP=Copiar las skins del instalador"
echo --- %CS_BUILD_STEP%
copy /B "..\..\build\bin\Skins\Classic Skin.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Full Glass.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Smoked Glass.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Windows Aero.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Windows Basic.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Windows XP Luna.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Windows 8.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Metro.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Classic Skin.skin7" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Windows Aero.skin7" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Windows 8.skin7" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Midnight.skin7" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Metro.skin7" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Metallic.skin7" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Immersive.skin" Output > nul
if errorlevel 1 goto build_failed
copy /B "..\..\build\bin\Skins\Immersive.skin7" Output > nul
if errorlevel 1 goto build_failed

REM ********* Build ADMX
set "CS_BUILD_STEP=Generar las politicas ADMX"
echo --- ADMX
if exist Output\PolicyDefinitions.zip (
  del Output\PolicyDefinitions.zip
)
cd ..\Localization\English
..\..\..\build\bin\Setup\StartMenu.exe -saveadmx en-US
@if ERRORLEVEL 1 goto build_failed
..\..\..\build\bin\Setup\ClassicExplorerSettings.exe -saveadmx en-US
@if ERRORLEVEL 1 goto build_failed
..\..\..\build\bin\Setup\ClassicIE_32.exe -saveadmx en-US
@if ERRORLEVEL 1 goto build_failed
md en-US
copy /B *.adml en-US > nul
if errorlevel 1 goto build_failed
set "CS_BUILD_STEP=Empaquetar PolicyDefinitions.zip"
echo --- %CS_BUILD_STEP%
where tar.exe >nul 2>&1
if errorlevel 1 (
	7z a -tzip ..\..\Setup\Output\PolicyDefinitions.zip *.admx en-US\*.adml PolicyDefinitions.rtf >nul
) else (
	tar -a -c -f ..\..\Setup\Output\PolicyDefinitions.zip *.admx en-US\*.adml PolicyDefinitions.rtf
)
if errorlevel 1 goto build_failed
rd /Q /S en-US
cd ..\..\Setup

exit /b 0

:build_failed
set "CS_BUILD_EXIT=%errorlevel%"
if "%CS_BUILD_EXIT%"=="0" set "CS_BUILD_EXIT=1"
echo ERROR: %CS_BUILD_STEP% (codigo %CS_BUILD_EXIT%).
exit /b %CS_BUILD_EXIT%
