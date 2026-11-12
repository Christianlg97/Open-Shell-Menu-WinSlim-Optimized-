@echo off
set PATH=C:\Program Files\7-Zip\;%PATH%
cd /d "%~dp0"

call _Version.bat

REM ********* Build MSI Checksums
echo --- MSI Checksums
..\..\build\bin\Release\Utility.exe crcmsi Temp
@if ERRORLEVEL 1 exit /b 1

REM ********* Build bootstrapper
echo --- Bootstrapper
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
if /i not "%CS_MSBUILD_TARGET%"=="Build" set "CS_MSBUILD_TARGET=Rebuild"

"%MSBuildExe%" Setup.sln /m /t:%CS_MSBUILD_TARGET% /p:Configuration="Release" /p:Platform="Win32" /verbosity:quiet /nologo
@if ERRORLEVEL 1 exit /b 1


powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\Clean-BuildDirectory.ps1" -RepositoryRoot "%~dp0..\.." -Path "%~dp0Final"
if errorlevel 1 exit /b 1
md Final

copy /B ..\..\build\bin\Release\Setup.exe Final\OpenShellSetup_%CS_VERSION_STR%.exe > nul
if errorlevel 1 exit /b 1

if defined APPVEYOR (
	appveyor PushArtifact Final\OpenShellSetup_%CS_VERSION_STR%.exe
)

REM ***** Collect PDBs

REM ********* Collect debug info
md Output\PDB32
md Output\PDB64
md Output\PDBARM64

REM Menu 32
copy /B ..\..\build\bin\Setup\StartMenu.pdb Output\PDB32 > nul
if errorlevel 1 exit /b 1
copy /B Output\StartMenu.exe Output\PDB32 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\StartMenuDLL.pdb Output\PDB32 > nul
if errorlevel 1 exit /b 1
copy /B Output\StartMenuDLL.dll Output\PDB32 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup\StartMenuHelper32.pdb Output\PDB32 > nul
if errorlevel 1 exit /b 1
copy /B Output\StartMenuHelper32.dll Output\PDB32 > nul
if errorlevel 1 exit /b 1

REM Menu 64

copy /B ..\..\build\bin\Setup64\StartMenu.pdb Output\PDB64 > nul
if errorlevel 1 exit /b 1
copy /B Output\x64\StartMenu.exe Output\PDB64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\StartMenuDLL.pdb Output\PDB64 > nul
if errorlevel 1 exit /b 1
copy /B Output\x64\StartMenuDLL.dll Output\PDB64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\Setup64\StartMenuHelper64.pdb Output\PDB64 > nul
if errorlevel 1 exit /b 1
copy /B Output\x64\StartMenuHelper64.dll Output\PDB64 > nul
if errorlevel 1 exit /b 1

REM Menu ARM64
copy /B ..\..\build\bin\SetupARM64\StartMenu.pdb Output\PDBARM64 > nul
if errorlevel 1 exit /b 1
copy /B Output\ARM64\StartMenu.exe Output\PDBARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\StartMenuDLL.pdb Output\PDBARM64 > nul
if errorlevel 1 exit /b 1
copy /B Output\ARM64\StartMenuDLL.dll Output\PDBARM64 > nul
if errorlevel 1 exit /b 1
copy /B ..\..\build\bin\SetupARM64\StartMenuHelper64.pdb Output\PDBARM64 > nul
if errorlevel 1 exit /b 1
copy /B Output\ARM64\StartMenuHelper64.dll Output\PDBARM64 > nul
if errorlevel 1 exit /b 1

REM ********* Source Index PDBs

set "PDBSTR_PATH=%CS_PDBSTR_PATH%"
if not defined PDBSTR_PATH set "PDBSTR_PATH=C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\srcsrv\pdbstr.exe"

if exist "%PDBSTR_PATH%" (
	echo --- Adding source index to PDBs
	call CreateSourceIndex.bat ..\.. > Output\pdbstr.txt

	for %%f in (Output\PDB32\*.pdb) do (
		"%PDBSTR_PATH%" -w -p:%%f -s:srcsrv -i:Output\pdbstr.txt
		if ERRORLEVEL 1 (
			echo Error adding source index to PDB
			exit /b 1
		)
	)

	for %%f in (Output\PDB64\*.pdb) do (
		"%PDBSTR_PATH%" -w -p:%%f -s:srcsrv -i:Output\pdbstr.txt
		if ERRORLEVEL 1 (
			echo Error adding source index to PDB
			exit /b 1
		)
	)

	for %%f in (Output\PDBARM64\*.pdb) do (
		"%PDBSTR_PATH%" -w -p:%%f -s:srcsrv -i:Output\pdbstr.txt
		if ERRORLEVEL 1 (
			echo Error adding source index to PDB
			exit /b 1
		)
	)
)

REM ********* Prepare symbols

set "SYMSTORE_PATH=%CS_SYMSTORE_PATH%"
if not defined SYMSTORE_PATH set "SYMSTORE_PATH=C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\symstore.exe"
if not exist "%SYMSTORE_PATH%" exit /b 1

"%SYMSTORE_PATH%" add /r /f Output\PDB32 /s Output\symbols /t OpenShell -:NOREFS > nul
if errorlevel 1 exit /b 1
"%SYMSTORE_PATH%" add /r /f Output\PDB64 /s Output\symbols /t OpenShell -:NOREFS > nul
if errorlevel 1 exit /b 1
"%SYMSTORE_PATH%" add /r /f Output\PDBARM64 /s Output\symbols /t OpenShell -:NOREFS > nul
if errorlevel 1 exit /b 1
rd /Q /S Output\symbols\000Admin > nul
del Output\symbols\pingme.txt > nul

rd /Q /S Output\PDB32
rd /Q /S Output\PDB64
rd /Q /S Output\PDBARM64

echo -- Creating symbols package
set CS_SYMBOLS_NAME=OpenShellSymbols_%CS_VERSION_STR%.7z

7z a -mx9 .\Final\%CS_SYMBOLS_NAME% .\Output\symbols\* > nul
if errorlevel 1 exit /b 1

if defined APPVEYOR (
	appveyor PushArtifact Final\%CS_SYMBOLS_NAME%
)

cd ..

REM ***** Collect Localization files

echo -- Creating localization package
cd Localization
7z a -r -x!en-US -x!*WixUI_en-us.wxl -x!*.adml -x!*.admx -x!*LocComments.txt ..\Setup\Final\OpenShellLoc.zip English ..\StartMenu\StartMenuL10N.ini ..\StartMenu\StartMenuHelper\StartMenuHelperL10N.ini English\OpenShellText-en-US.wxl English\OpenShellEULA.rtf > nul
if errorlevel 1 exit /b 1
cd ..

cd Setup

copy /B Output\Utility.exe .\Final > nul
if errorlevel 1 exit /b 1

if defined APPVEYOR (
	appveyor PushArtifact Output\Utility.exe
)

exit /b 0
