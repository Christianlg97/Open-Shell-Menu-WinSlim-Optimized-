param(
    [string]$Version = '4.4.1000',
    [ValidateSet('English','Spanish','French','German','Italian','Polish','Russian','ChineseCN','ChineseTW')]
    [string]$Language = 'English',
    [switch]$Full,
    [switch]$MsiOnly,
    [switch]$Legacy,
    [switch]$CheckOnly,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setup = Join-Path $repository 'Src\Setup'
try {
    if ($Full -and $MsiOnly) { throw '-Full and -MsiOnly cannot be combined.' }
    $buildFull = $Full -or -not $MsiOnly
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') { throw 'Version must be X.Y.Z, optionally followed by -suffix.' }
    $numeric = [version]($Version.Split('-')[0])
    if ($numeric.Major -gt 255 -or $numeric.Minor -gt 255 -or $numeric.Build -gt 65535) { throw 'Version exceeds MSI limits (255.255.65535).' }
    $missing = [Collections.Generic.List[string]]::new()
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { $missing.Add('Visual Studio 2022 with Desktop C++, ATL and a Windows SDK') }
    else {
        $installation = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
        if (-not $installation -or -not (Test-Path -LiteralPath (Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'))) {
            $missing.Add('Visual Studio MSBuild and the C++ workload')
        }
        elseif (-not (Test-Path -LiteralPath (Join-Path $installation 'VC\Tools\MSVC'))) {
            $missing.Add('Visual Studio Desktop development with C++')
        }
        else {
            $compiler=Get-ChildItem -LiteralPath (Join-Path $installation 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if (-not $compiler -or -not (Test-Path -LiteralPath (Join-Path $compiler.FullName 'atlmfc\include\atlbase.h'))) {
                $missing.Add('Visual C++ ATL support')
            }
            if ($buildFull -and (-not $compiler -or -not (Test-Path -LiteralPath (Join-Path $compiler.FullName 'lib\arm64')))) {
                $missing.Add('Visual C++ ARM64 build tools')
            }
            if ($buildFull -and $compiler -and (-not (Test-Path -LiteralPath (Join-Path $compiler.FullName 'atlmfc\lib\arm64')))) {
                $missing.Add('Visual C++ ATL for ARM64')
            }
        }
    }
    $directories = @(
        'C:\Program Files (x86)\HTML Help Workshop',
        'C:\Program Files (x86)\WiX Toolset v3.14\bin',
        'C:\Program Files\7-Zip',
        (Join-Path $env:USERPROFILE '.cargo\bin')
    )
    if ($env:WIX) { $directories += (Join-Path $env:WIX 'bin') }
    $directories += Get-ChildItem -LiteralPath ${env:ProgramFiles(x86)} -Directory -Filter 'WiX Toolset v3*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'bin' }
    $env:PATH = ($directories -join ';') + ';' + $env:PATH
    $commands = @('candle.exe','light.exe','hhc.exe','tar.exe')
    if (-not $Legacy) { $commands += @('cargo.exe','rustc.exe','rustup.exe') }
    if (-not $SkipTests) { $commands += 'python.exe' }
    if ($buildFull) {
        $commands += '7z.exe'
        $symstore=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\symstore.exe'
        if (-not (Test-Path -LiteralPath $symstore)) { $missing.Add('Windows SDK Debugging Tools (x64 symstore.exe)') }
    }
    foreach ($command in $commands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { $missing.Add($command) }
    }
    if ($missing.Count) { throw ('Missing prerequisites: ' + ($missing -join ', ')) }
    if ($CheckOnly) { Write-Host 'Build prerequisites found. No compilation was started.'; exit 0 }

    $env:CS_VERSION = $Version
    $env:CS_BUILD_ARM64 = if ($buildFull) { '1' } else { '0' }
    $env:WinSlimUseRustCore = if ($Legacy) { 'false' } else { 'true' }
    if ($Legacy) { Remove-Item Env:CS_WINSLIM_RUST -ErrorAction SilentlyContinue }
    else { $env:CS_WINSLIM_RUST = '1' }
    if (-not $Legacy) {
        $targets = @('x86_64-pc-windows-msvc','i686-pc-windows-msvc')
        if ($buildFull) { $targets += 'aarch64-pc-windows-msvc' }
        & rustup target add @targets
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Rust targets.' }
        if (-not $SkipTests) {
            foreach ($target in @('x86_64-pc-windows-msvc','i686-pc-windows-msvc')) {
                & cargo test --locked --manifest-path (Join-Path $repository 'Src\RustCore\Cargo.toml') --target-dir (Join-Path $repository 'build\rust-tests') --target $target
                if ($LASTEXITCODE -ne 0) { throw "Rust tests failed for $target" }
            }
        }
    }
    if (-not $SkipTests) {
        $python = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $python) { throw 'Python 3 is required for the static and native regression checks; install it or explicitly use -SkipTests.' }
        & $python.Source (Join-Path $PSScriptRoot 'verify.py')
        if ($LASTEXITCODE -ne 0) { throw 'Regression checks failed.' }
    }
    function Invoke-SetupScript([string]$Name) {
        Push-Location $setup
        try {
            & $env:ComSpec /d /c "call .\$Name"
            if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
        } finally { Pop-Location }
    }
    Invoke-SetupScript 'BuildBinaries.bat'
    if (-not $SkipTests) {
        $msbuild=Join-Path $installation 'MSBuild\Current\Bin\MSBuild.exe'
        foreach ($platform in @('x64','Win32')) {
            & $msbuild (Join-Path $PSScriptRoot 'CoreTests.vcxproj') /t:Rebuild /p:Configuration=Release "/p:Platform=$platform" /nologo /verbosity:minimal
            if ($LASTEXITCODE -ne 0) { throw "Native core ABI test build failed for $platform" }
            & (Join-Path $repository "build\tests\$platform\CoreTests.exe")
            if ($LASTEXITCODE -ne 0) { throw "Native core ABI regression failed for $platform" }
        }
    }
    Invoke-SetupScript ('_Build' + $Language + '.bat')
    if ($buildFull) { Invoke-SetupScript 'BuildArchives.bat' }
    $final = Join-Path $setup 'Final'
    New-Item -ItemType Directory -Path $final -Force | Out-Null
    $versionName = $Version.Replace('.', '_')
    $produced=[Collections.Generic.List[string]]::new()
    $architectures = @{'x86'='Setup32.msi'; 'x64'='Setup64.msi'}
    if ($buildFull) { $architectures['ARM64']='SetupARM64.msi' }
    foreach ($architecture in $architectures.Keys) {
        $source = Join-Path (Join-Path $setup 'Temp') $architectures[$architecture]
        $destination = Join-Path $final "OpenShellSetup_${versionName}_${Language}_${architecture}.msi"
        if (-not (Test-Path -LiteralPath $source)) { throw "Installer not generated: $source" }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        & (Join-Path $PSScriptRoot 'Verify-Msi.ps1') -MsiPath $destination -Architecture $architecture -Version $Version
        $produced.Add($destination)
        Write-Host "Created: $destination"
    }
    if ($buildFull) {
        foreach ($artifact in @("OpenShellSetup_${versionName}.exe", "OpenShellSymbols_${versionName}.7z", 'OpenShellLoc.zip', 'Utility.exe')) {
            $artifactPath=Join-Path $final $artifact
            if (-not (Test-Path -LiteralPath $artifactPath) -or (Get-Item -LiteralPath $artifactPath).Length -eq 0) { throw "Distribution artifact not generated: $artifactPath" }
            $produced.Add($artifactPath)
        }
    }
    $hashes = $produced |
        Get-FileHash -Algorithm SHA256 | ForEach-Object { '{0}  {1}' -f $_.Hash, [IO.Path]::GetFileName($_.Path) }
    $hashes | Set-Content -LiteralPath (Join-Path $final "SHA256_${versionName}.txt") -Encoding ASCII
    Write-Host "Done. Installers are in $final"
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
