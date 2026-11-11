# Dot-sourced by Build.ps1. Detection never downloads, installs or compiles.
function Get-WinSlimToolsRoot {
    Join-Path $env:LOCALAPPDATA 'OpenShellBuild\Tools'
}

function Add-WinSlimToolPaths {
    $root=Get-WinSlimToolsRoot
    $paths=@(
        (Join-Path $root 'wix-3.14.1'),
        (Join-Path $env:ProgramFiles '7-Zip'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip'),
        (Join-Path ${env:ProgramFiles(x86)} 'HTML Help Workshop'),
        (Join-Path $env:USERPROFILE '.cargo\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313'),
        (Join-Path $env:SystemRoot 'System32')
    )
    if ($env:CARGO_HOME) { $paths += Join-Path $env:CARGO_HOME 'bin' }
    if ($env:WIX) { $paths += @($env:WIX, (Join-Path $env:WIX 'bin')) }
    $paths += Get-ChildItem -LiteralPath ${env:ProgramFiles(x86)} -Directory -Filter 'WiX Toolset v3*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'bin' }
    $paths += Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python\Python*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    $env:PATH=(@($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) + @($env:PATH -split ';') | Select-Object -Unique) -join ';'
}

function Find-WinSlimCommand([string]$Name) {
    $command=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Test-WinSlimCommand([string]$FilePath, [string[]]$Arguments, [version]$MinimumVersion=$null) {
    # PowerShell 5.1 treats native stderr as ErrorRecord; rustup legitimately
    # writes version information there even with a successful exit status.
    $ErrorActionPreference='Continue'
    $output=@(& $FilePath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($MinimumVersion) {
        $match=[regex]::Match(($output -join ' '),'\b(\d+\.\d+\.\d+)\b')
        return $match.Success -and [version]$match.Groups[1].Value -ge $MinimumVersion
    }
    return $true
}

function Get-WinSlimPrerequisites([bool]$Full, [bool]$Legacy, [bool]$SkipTests) {
    Add-WinSlimToolPaths
    $missing=[Collections.Generic.List[object]]::new()
    $installation=$null; $compiler=$null; $msbuild=$null
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installation=& $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.Component.MSBuild -property installationPath
        if ($installation) {
            $msbuild=Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
            $versionFile=Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.v143.default.txt'
            if (Test-Path -LiteralPath $versionFile) {
                $toolVersion=([IO.File]::ReadAllText($versionFile)).Trim()
                if ($toolVersion -match '^14\.\d+\.\d+$') { $compiler=Join-Path $installation "VC\Tools\MSVC\$toolVersion" }
            }
        }
    }
    if (-not $msbuild -or -not (Test-Path -LiteralPath $msbuild) -or -not $compiler -or
        -not (Test-Path -LiteralPath (Join-Path $compiler 'bin\Hostx64\x64\cl.exe')) -or
        -not (Test-Path -LiteralPath (Join-Path $compiler 'lib\x86\libcmt.lib'))) {
        $missing.Add(@{Id='visualstudio'; Label='Visual Studio 2022 Build Tools / MSVC v143 x86/x64'})
    }
    if (-not $compiler -or -not (Test-Path -LiteralPath (Join-Path $compiler 'atlmfc\include\atlbase.h')) -or
        -not (Test-Path -LiteralPath (Join-Path $compiler 'atlmfc\lib\x64\atls.lib')) -or
        -not (Test-Path -LiteralPath (Join-Path $compiler 'atlmfc\lib\x86\atls.lib'))) {
        $missing.Add(@{Id='atl'; Label='Visual C++ ATL x86/x64'})
    }
    if ($Full) {
        if (-not $compiler -or -not (Test-Path -LiteralPath (Join-Path $compiler 'lib\arm64\libcmt.lib'))) {
            $missing.Add(@{Id='arm64'; Label='Visual C++ ARM64 build tools'})
        }
        if (-not $compiler -or -not (Test-Path -LiteralPath (Join-Path $compiler 'atlmfc\lib\arm64\atls.lib'))) {
            $missing.Add(@{Id='atlarm64'; Label='Visual C++ ATL ARM64'})
        }
    }
    $sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    $kits=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
    if ($kits -and $kits.PSObject.Properties['KitsRoot10']) { $sdkRoot=$kits.KitsRoot10 }
    $sdkVersions=@(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Include') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^10\.0\.\d+\.0$' } | Sort-Object { [version]$_.Name } -Descending)
    $sdkReady=$false
    foreach ($sdk in $sdkVersions) {
        $ready=(Test-Path -LiteralPath (Join-Path $sdk.FullName 'um\Windows.h')) -and
            (Test-Path -LiteralPath (Join-Path $sdk.FullName 'ucrt\stdlib.h')) -and
            (Test-Path -LiteralPath (Join-Path $sdkRoot "bin\$($sdk.Name)\x64\rc.exe")) -and
            (Test-Path -LiteralPath (Join-Path $sdkRoot "bin\$($sdk.Name)\x64\mt.exe"))
        foreach ($arch in @('x86','x64') + $(if ($Full) { @('arm64') })) {
            $ready=$ready -and (Test-Path -LiteralPath (Join-Path $sdkRoot "Lib\$($sdk.Name)\um\$arch\kernel32.lib")) -and
                (Test-Path -LiteralPath (Join-Path $sdkRoot "Lib\$($sdk.Name)\ucrt\$arch\ucrt.lib"))
        }
        if ($ready) { $sdkReady=$true; break }
    }
    if (-not $sdkReady) { $missing.Add(@{Id='sdk'; Label='Windows 10/11 SDK (headers and libraries)'}) }
    $symstore=Join-Path $sdkRoot 'Debuggers\x64\symstore.exe'
    $pdbstr=Join-Path $sdkRoot 'Debuggers\x86\srcsrv\pdbstr.exe'
    if ($Full -and -not (Test-Path -LiteralPath $symstore)) { $missing.Add(@{Id='debuggers'; Label='Windows SDK Debugging Tools (symstore)'}) }
    $candle=Find-WinSlimCommand 'candle.exe'; $light=Find-WinSlimCommand 'light.exe'
    if (-not $candle -or -not $light -or [Diagnostics.FileVersionInfo]::GetVersionInfo($candle).FileMajorPart -ne 3 -or
        [Diagnostics.FileVersionInfo]::GetVersionInfo($light).FileMajorPart -ne 3) {
        $missing.Add(@{Id='wix'; Label='WiX Toolset 3.x (candle/light)'})
    }
    if (-not (Find-WinSlimCommand 'hhc.exe')) { $missing.Add(@{Id='htmlhelp'; Label='HTML Help Workshop (hhc)'}) }
    if ($Full -and -not (Find-WinSlimCommand '7z.exe')) { $missing.Add(@{Id='sevenzip'; Label='7-Zip'}) }
    if (-not (Find-WinSlimCommand 'tar.exe') -and -not (Find-WinSlimCommand '7z.exe')) { $missing.Add(@{Id='tar'; Label='tar.exe (Windows) or 7-Zip fallback'}) }
    if (-not $Legacy) {
        $rustReady=$true
        foreach ($command in 'cargo.exe','rustc.exe','rustup.exe') {
            $tool=Find-WinSlimCommand $command
            if (-not $tool) { $rustReady=$false; break }
            $minimum=if ($command -eq 'rustup.exe') { $null } else { [version]'1.83.0' }
            if (-not (Test-WinSlimCommand $tool @('--version') -MinimumVersion $minimum)) { $rustReady=$false; break }
        }
        if (-not $rustReady) { $missing.Add(@{Id='rust'; Label='Rust stable MSVC 1.83+ / cargo / rustup'}) }
    }
    $python=Find-WinSlimCommand 'python.exe'
    if (-not $SkipTests) {
        $pythonReady=$false
        if ($python -and $python -notlike '*\Microsoft\WindowsApps\*') {
            $pythonReady=Test-WinSlimCommand $python @('-c','import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)')
        }
        if (-not $pythonReady) { $missing.Add(@{Id='python'; Label='Python 3.11 or newer'}) }
    }
    [pscustomobject]@{ Missing=@($missing.ToArray()); Installation=$installation; MSBuild=$msbuild; Compiler=$compiler;
        SdkRoot=$sdkRoot; Symstore=$symstore; Pdbstr=$pdbstr; Python=$python }
}

function Get-WinSlimDownload([string]$Name, [string]$Uri, [string]$Sha256='', [string]$Publisher='') {
    if (-not $Sha256 -and -not $Publisher) { throw "No integrity check configured for $Name" }
    $directory=Join-Path $env:LOCALAPPDATA 'OpenShellBuild\Downloads'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $destination=Join-Path $directory $Name
    function Test-Download([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        if ($Sha256) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Sha256 }
        $signature=Get-AuthenticodeSignature -LiteralPath $Path
        return $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match $Publisher
    }
    if (Test-Download $destination) { return $destination }
    $previousProgress=$ProgressPreference
    try {
        $ProgressPreference='SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $partial=$destination+'.partial'
        for ($attempt=1; $attempt -le 3; $attempt++) {
            try {
                Write-Host "Descargando $Name..."
                Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial -TimeoutSec 180
                if (-not (Test-Download $partial)) { throw "Integrity/signature verification failed: $Name" }
                Move-Item -LiteralPath $partial -Destination $destination -Force
                return $destination
            } catch {
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds $attempt
            }
        }
    } finally { $ProgressPreference=$previousProgress }
}

function Wait-WinSlimInstallerProcess($Process, [int]$TimeoutSeconds, [string]$LogPath) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $nextNotice=15
    # Keep the process handle before it exits so ExitCode remains available.
    $null=$Process.Handle
    while (-not $Process.WaitForExit(1000)) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw [TimeoutException]::new("El instalador no termina (PID $($Process.Id)). No se iniciara la compilacion. Registro: $LogPath")
        }
        if ($timer.Elapsed.TotalSeconds -ge $nextNotice) {
            Write-Host ("Instalacion en curso: {0}s, PID {1}. Registro: {2}" -f [int]$timer.Elapsed.TotalSeconds,$Process.Id,$LogPath)
            $nextNotice+=15
        }
    }
    return $Process.ExitCode
}

function Invoke-WinSlimInstaller([string]$FilePath, [string[]]$Arguments, [switch]$Elevated, [string]$ArgumentLine='', [string]$WorkingDirectory='', [int]$TimeoutSeconds=0, [string]$LogPath='') {
    $argumentsQuoted=@(foreach ($argument in $Arguments) {
        if ($argument.Contains('"') -or $argument.Contains("`n") -or $argument.Contains("`r")) { throw 'Invalid installer argument' }
        # msiexec parses its raw command line: quoting /i or /qn opens a
        # hidden help dialog instead of installing. Quote only values that need it.
        if ($argument.Length -eq 0 -or $argument -match '\s') { '"'+[regex]::Replace($argument,'(\\+)$','$1$1')+'"' }
        else { $argument }
    }) -join ' '
    if ($ArgumentLine) { $argumentsQuoted=$ArgumentLine }
    $options=@{FilePath=$FilePath; ArgumentList=$argumentsQuoted; Wait=$true; PassThru=$true; WindowStyle='Hidden'}
    if ($TimeoutSeconds -gt 0) { $options.Remove('Wait') }
    if ($WorkingDirectory) { $options.WorkingDirectory=$WorkingDirectory }
    $identity=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($Elevated -and -not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'Windows solicitara permisos de administrador para instalar este requisito.'
        $options.Verb='RunAs'
    }
    try { $process=Start-Process @options }
    catch { throw "No se pudo iniciar el instalador (comprueba la solicitud UAC): $($_.Exception.Message)" }
    $exitCode=if ($TimeoutSeconds -gt 0) { Wait-WinSlimInstallerProcess $process $TimeoutSeconds $LogPath } else { $process.ExitCode }
    if ($exitCode -in @(3010,1641)) { throw 'La instalacion requiere reiniciar Windows. Reinicia y vuelve a ejecutar build.cmd; no se ha iniciado la compilacion.' }
    if ($exitCode -ne 0) { throw "Installer failed ($exitCode): $FilePath. Registro: $LogPath" }
}

function Disable-WinSlimLegacyHelpUpdate([string]$Text) {
    $pattern='(?im)^[ \t]*RunPostSetupCommands[ \t]*=[ \t]*HHUpdate[^\r\n]*'
    if ([regex]::Matches($Text,$pattern).Count -ne 3) { throw 'Unexpected HTML Help installation manifest' }
    [regex]::Replace($Text,$pattern,'; Legacy hhupd disabled; Windows already includes the HTML Help runtime.')
}

function Install-WinSlimPrerequisites($State, [bool]$Full, [bool]$Legacy, [bool]$SkipTests) {
    $ids=@($State.Missing | ForEach-Object { $_.Id })
    $root=Get-WinSlimToolsRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (@($ids | Where-Object { $_ -in @('visualstudio','atl','arm64','atlarm64') }).Count) {
        $components=@('Microsoft.VisualStudio.Workload.VCTools','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','Microsoft.VisualStudio.Component.VC.ATL')
        if ($Full) { $components += @('Microsoft.VisualStudio.Component.VC.Tools.ARM64','Microsoft.VisualStudio.Component.VC.ATL.ARM64') }
        $existingInstaller=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
        if ($State.Installation -and (Test-Path -LiteralPath $existingInstaller)) {
            $bootstrapper=$existingInstaller
            # --wait is a bootstrapper option, not an Installer setup.exe option.
            $arguments=@('modify','--quiet','--norestart','--installPath',$State.Installation)
        } else {
            $bootstrapper=Get-WinSlimDownload 'vs_buildtools_2022.exe' 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -Publisher 'O=Microsoft Corporation'
            $arguments=@('--quiet','--wait','--norestart','--nocache')
        }
        foreach ($component in $components) { $arguments+=@('--add',$component) }
        Write-Host 'Instalando los componentes necesarios de Visual Studio 2022...'
        Invoke-WinSlimInstaller $bootstrapper $arguments -Elevated
        # VS can install an SDK as a dependency; don't provision it twice.
        $ids=@((Get-WinSlimPrerequisites $Full $Legacy $SkipTests).Missing | ForEach-Object { $_.Id })
    }
    if ('sdk' -in $ids -or 'debuggers' -in $ids) {
        $sdk=Get-WinSlimDownload 'winsdksetup-22621.exe' 'https://download.microsoft.com/download/3/b/d/3bd97f81-3f5b-4922-b86d-dc5145cd6bfe/windowssdk/winsdksetup.exe' -Sha256 '3f73f59566b0cf3eddddaf61ad72bb0c6e4588a5d9e004abf68115b752ebbbd8'
        $features=@()
        if ('sdk' -in $ids) {
            $features+='OptionId.DesktopCPPx64' # includes x86, headers, libraries and UCRT
            if ($Full) { $features+='OptionId.DesktopCPParm64' }
        }
        if ($Full) { $features+='OptionId.WindowsDesktopDebuggers' }
        Write-Host 'Instalando los componentes necesarios del Windows SDK...'
        Invoke-WinSlimInstaller $sdk (@('/quiet','/norestart','/features')+$features) -Elevated
    }
    if ('wix' -in $ids) {
        $zip=Get-WinSlimDownload 'wix-3.14.1.zip' 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -Sha256 '6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31'
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $root 'wix-3.14.1') -Force
    }
    if ('htmlhelp' -in $ids) {
        # The Microsoft download is no longer online; these are the original
        # Microsoft bytes preserved by Archive.org, pinned by SHA-256.
        $sfx=Get-WinSlimDownload 'htmlhelp-1.32.exe' 'https://web.archive.org/web/20200918004813id_/https://download.microsoft.com/download/0/A/9/0A939EF6-E31C-430F-A3DF-DFAE7960D564/htmlhelp.exe' -Sha256 'b2b3140d42a818870c1ab13c1c7b8d4536f22bd994fa90aade89729a6009a3ae'
        $help=Join-Path $root 'htmlhelp'
        New-Item -ItemType Directory -Path $help -Force | Out-Null
        $bytes=[IO.File]::ReadAllBytes($sfx)
        $cab=Join-Path $help 'htmlhelp.cab'
        $cabBytes=New-Object byte[] 3419956
        [Array]::Copy($bytes,67180,$cabBytes,0,$cabBytes.Length)
        [IO.File]::WriteAllBytes($cab,$cabBytes)
        & (Join-Path $env:SystemRoot 'System32\expand.exe') '-F:*' $cab $help | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to extract HTML Help Workshop' }
        $inf=Join-Path $help 'htmlhelp_fixed.inf'
        $originalInf=[IO.File]::ReadAllText((Join-Path $help 'htmlhelp.inf'))
        $fixedInf=Disable-WinSlimLegacyHelpUpdate $originalInf
        [IO.File]::WriteAllText($inf,$fixedInf,[Text.Encoding]::ASCII)
        # Install the 32-bit compiler and register itcc.dll for full-text search.
        # The original obsolete hhupd updater would otherwise open a dialog.
        $rundll=Join-Path $env:SystemRoot 'SysWOW64\rundll32.exe'
        Write-Host 'Instalando HTML Help Workshop...'
        $argumentLine='advpack.dll,LaunchINFSectionEx "{0}",,,12,N' -f $inf
        Invoke-WinSlimInstaller -FilePath $rundll -ArgumentLine $argumentLine -WorkingDirectory $help -Elevated
    }
    if ('sevenzip' -in $ids -or 'tar' -in $ids) {
        $msi=Get-WinSlimDownload '7zip-26.06-x64.msi' 'https://github.com/ip7z/7zip/releases/download/26.06/7z2606-x64.msi' -Sha256 '6dc822569e777d9a3ecd5ffcbc22b55600af87e6c5d9810a64e8566cf5a4af9f'
        $logDirectory=Join-Path $env:LOCALAPPDATA 'OpenShellBuild\Logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $log=Join-Path $logDirectory ('7zip-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+"-$PID.log")
        Write-Host 'Instalando 7-Zip...'
        Write-Host "Registro de Windows Installer: $log"
        Invoke-WinSlimInstaller (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/i',$msi,'/qn','/norestart','/L*V',$log) -Elevated -TimeoutSeconds 300 -LogPath $log
    }
    Add-WinSlimToolPaths
    if ('rust' -in $ids -and -not $Legacy) {
        $uri='https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
        $hash=(([string](Invoke-WebRequest -UseBasicParsing -Uri ($uri+'.sha256')).Content).Trim() -split '\s+')[0]
        if ($hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid Rust installer checksum' }
        $rust=Get-WinSlimDownload 'rustup-init.exe' $uri -Sha256 $hash
        Write-Host 'Instalando Rust stable MSVC...'
        Invoke-WinSlimInstaller $rust @('-y','--profile','minimal','--default-host','x86_64-pc-windows-msvc','--default-toolchain','stable','--no-modify-path')
        Add-WinSlimToolPaths
    }
    if ('python' -in $ids -and -not $SkipTests) {
        $python=Get-WinSlimDownload 'python-3.13.17-amd64.exe' 'https://www.python.org/ftp/python/3.13.17/python-3.13.17-amd64.exe' -Publisher 'O=Python Software Foundation'
        Write-Host 'Instalando Python...'
        Invoke-WinSlimInstaller $python @('/quiet','InstallAllUsers=0','PrependPath=0','Include_launcher=0','Include_test=0','Include_doc=0','Include_pip=0')
    }
    Add-WinSlimToolPaths
}

function Ensure-WinSlimPrerequisites([bool]$Full, [bool]$Legacy, [bool]$SkipTests, [bool]$CheckOnly, [bool]$NoInstall) {
    $state=Get-WinSlimPrerequisites $Full $Legacy $SkipTests
    if ($state.Missing.Count) {
        $labels=@($state.Missing | ForEach-Object { $_.Label }) -join ', '
        if ($CheckOnly -or $NoInstall) { throw "Missing prerequisites: $labels" }
        Write-Host "Faltan requisitos: $labels"
        Install-WinSlimPrerequisites $state $Full $Legacy $SkipTests
        $state=Get-WinSlimPrerequisites $Full $Legacy $SkipTests
        if ($state.Missing.Count) { throw ('Prerequisites still missing after installation: '+(@($state.Missing | ForEach-Object { $_.Label }) -join ', ')) }
    }
    return $state
}
