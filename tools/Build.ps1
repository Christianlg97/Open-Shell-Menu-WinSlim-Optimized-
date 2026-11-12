param(
    [string]$Version = '4.4.1007',
    [ValidateSet('English','Spanish','French','German','Italian','Polish','Russian','ChineseCN','ChineseTW')]
    [string]$Language = 'English',
    [switch]$Full,
    [switch]$MsiOnly,
    [switch]$Legacy,
    [switch]$CheckOnly,
    [switch]$SkipTests,
    [switch]$NoInstall,
    [switch]$InstallOnly,
    [switch]$Incremental,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setup = Join-Path $repository 'Src\Setup'
try {
    if (-not $OutputDirectory) {
        $workspace=Split-Path $repository -Parent
        $releaseRoot=if (Test-Path -LiteralPath (Join-Path $workspace 'build.cmd')) { $workspace } else { $repository }
        $OutputDirectory=Join-Path $releaseRoot 'Release'
    }
    $OutputDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    Write-Host "Carpeta de resultados: $OutputDirectory"
    if ($Full -and $MsiOnly) { throw '-Full and -MsiOnly cannot be combined.' }
    $buildFull = $Full -or -not $MsiOnly
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$') { throw 'Version must be X.Y.Z, optionally followed by -suffix.' }
    $numeric = [version]($Version.Split('-')[0])
    if ($numeric.Major -gt 255 -or $numeric.Minor -gt 255 -or $numeric.Build -gt 65535) { throw 'Version exceeds MSI limits (255.255.65535).' }
    . (Join-Path $PSScriptRoot 'Prerequisites.ps1')
    if ($CheckOnly -and $InstallOnly) { throw '-CheckOnly and -InstallOnly cannot be combined.' }
    $prerequisites=Ensure-WinSlimPrerequisites -Full $buildFull -Legacy ([bool]$Legacy) -SkipTests ([bool]$SkipTests) -CheckOnly ([bool]$CheckOnly) -NoInstall ([bool]$NoInstall)
    if ($CheckOnly -or $InstallOnly) { Write-Host 'Build prerequisites found. No compilation was started.'; exit 0 }
    $installation=$prerequisites.Installation
    $env:CS_MSBUILD_PATH=$prerequisites.MSBuild
    $env:CS_SYMSTORE_PATH=$prerequisites.Symstore
    $env:CS_PDBSTR_PATH=$prerequisites.Pdbstr

    $env:CS_VERSION = $Version
    $env:CS_BUILD_ARM64 = if ($buildFull) { '1' } else { '0' }
    # Rebuild stays the default for distributable output. -Incremental reuses
    # up-to-date objects for local iterations; MSBuild still tracks changed flags.
    $msbuildTarget = if ($Incremental) { 'Build' } else { 'Rebuild' }
    $env:CS_MSBUILD_TARGET = $msbuildTarget
    $env:WinSlimUseRustCore = if ($Legacy) { 'false' } else { 'true' }
    if ($Legacy) { Remove-Item Env:CS_WINSLIM_RUST -ErrorAction SilentlyContinue }
    else { $env:CS_WINSLIM_RUST = '1' }
    if (-not $Legacy) {
        $targets = @('x86_64-pc-windows-msvc','i686-pc-windows-msvc')
        if ($buildFull) { $targets += 'aarch64-pc-windows-msvc' }
        if ($NoInstall) {
            $installedTargets=@(& rustup target list --installed)
            if ($LASTEXITCODE -ne 0 -or @($targets | Where-Object { $_ -notin $installedTargets }).Count) {
                throw 'Required Rust targets are missing. Run build.cmd without -NoInstall to prepare them.'
            }
        } else {
            & rustup target add @targets
            if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the Rust targets.' }
        }
        if (-not $SkipTests) {
            foreach ($target in @('x86_64-pc-windows-msvc','i686-pc-windows-msvc')) {
                & cargo test --locked --manifest-path (Join-Path $repository 'Src\RustCore\Cargo.toml') --target-dir (Join-Path $repository 'build\rust-tests') --target $target
                if ($LASTEXITCODE -ne 0) { throw "Rust tests failed for $target" }
            }
        }
    }
    if (-not $SkipTests) {
        & (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1') 6>$null
        & (Join-Path $PSScriptRoot 'Test-BuildLauncher.ps1') 6>$null
        & (Join-Path $PSScriptRoot 'Test-CmdHost.ps1') 6>$null
        $python = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $python) { throw 'Python 3 is required for the static and native regression checks; install it or explicitly use -SkipTests.' }
        & $python.Source (Join-Path $PSScriptRoot 'verify.py')
        if ($LASTEXITCODE -ne 0) { throw 'Source checks failed' }
        & $python.Source (Join-Path $PSScriptRoot 'Test-InstallerSource.py')
        if ($LASTEXITCODE -ne 0) { throw 'Regression checks failed.' }
        & $python.Source (Join-Path $PSScriptRoot 'Test-WinSlimProfile.py')
        if ($LASTEXITCODE -ne 0) { throw 'WinSlim profile or bundled assets checks failed.' }
        & $python.Source (Join-Path $PSScriptRoot 'Test-BitmapCache.py')
        if ($LASTEXITCODE -ne 0) { throw 'Bitmap cache orientation regression failed.' }
        & $python.Source (Join-Path $PSScriptRoot 'Test-OpenShellCaches.py')
        if ($LASTEXITCODE -ne 0) { throw 'Open-Shell cache maintenance regression failed.' }
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
            & $msbuild (Join-Path $PSScriptRoot 'CoreTests.vcxproj') "/t:$msbuildTarget" /p:Configuration=Release "/p:Platform=$platform" /nologo /verbosity:minimal
            if ($LASTEXITCODE -ne 0) { throw "Native core ABI test build failed for $platform" }
            & (Join-Path $repository "build\tests\$platform\CoreTests.exe")
            if ($LASTEXITCODE -ne 0) { throw "Native core ABI regression failed for $platform" }
        }
    }
    function Reset-WinSlimMsiIntegrity {
        # light.exe running elevated labels its MSI databases High (no write-up). A later
        # build with the normal token could not delete them, so lower them to Medium.
        $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
        foreach ($folder in 'Temp','Final') {
            $path=Join-Path $setup $folder
            if (-not (Test-Path -LiteralPath $path)) { continue }
            foreach ($msi in Get-ChildItem -LiteralPath $path -Filter '*.msi' -File -ErrorAction SilentlyContinue) {
                $null=& icacls.exe $msi.FullName /setintegritylevel M /Q
                if ($LASTEXITCODE -ne 0) { Write-Warning "No se pudo bajar la etiqueta de integridad de $($msi.FullName)" }
            }
        }
    }
    try { Invoke-SetupScript ('_Build' + $Language + '.bat') }
    finally { Reset-WinSlimMsiIntegrity }
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
    # Windows PowerShell 5.1 does not bind plain strings from the pipeline to Get-FileHash, so pass the paths explicitly.
    $hashes = @(Get-FileHash -LiteralPath $produced.ToArray() -Algorithm SHA256 -ErrorAction Stop |
        ForEach-Object { '{0}  {1}' -f $_.Hash, [IO.Path]::GetFileName($_.Path) })
    if ($hashes.Count -ne $produced.Count) { throw "SHA256 generation failed: $($hashes.Count) of $($produced.Count) artifacts hashed" }
    $hashFile=Join-Path $final "SHA256_${versionName}.txt"
    Set-Content -LiteralPath $hashFile -Value $hashes -Encoding ASCII
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($artifact in @($produced.ToArray())+@($hashFile)) {
        $destination=Join-Path $OutputDirectory ([IO.Path]::GetFileName($artifact))
        if (-not [string]::Equals([IO.Path]::GetFullPath($artifact),[IO.Path]::GetFullPath($destination),[StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $artifact -Destination $destination -Force
        }
        Write-Host "Resultado: $destination"
    }
    Write-Host "Build completado. Resultados en $OutputDirectory"
    exit 0
} catch {
    Write-Host ('ERROR: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}
