# Keep these public parameters aligned with Build.ps1. Only explicitly supplied
# values are forwarded, so Build.ps1 remains the owner of all defaults.
param(
    [string]$Version,
    [string]$Language,
    [switch]$Full,
    [switch]$MsiOnly,
    [switch]$Legacy,
    [switch]$CheckOnly,
    [switch]$SkipTests,
    [switch]$NoInstall,
    [switch]$InstallOnly,
    [switch]$Incremental,
    [string]$OutputDirectory,
    [switch]$WinSlimElevated
)

function Test-WinSlimAdministrator {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WinSlimProtectedOutput {
    # light.exe running elevated writes MSI databases with a High integrity label
    # (no write-up). A build with the normal token cannot delete them, so the next
    # cleanup fails with "access denied". Build.ps1 lowers that label on new MSIs;
    # leftovers from an older elevated build need one elevated build to replace them.
    $setup=Join-Path (Split-Path $PSScriptRoot -Parent) 'Src\Setup'
    foreach ($folder in 'Temp','Output','Final') {
        $path=Join-Path $setup $folder
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue) {
            if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) { continue }
            # Opening for write never truncates or changes the file.
            try { $file.Open([IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]'ReadWrite, Delete').Dispose() }
            catch [UnauthorizedAccessException] { return $true }
            catch { }
        }
    }
    return $false
}

function Test-WinSlimElevationRequired([hashtable]$Parameters) {
    # Only installers, and outputs left by an older elevated build, need administrator
    # rights. Otherwise compile with the user's normal token and skip the UAC prompt.
    if (Test-WinSlimProtectedOutput) {
        Write-Host 'Hay archivos de un build elevado anterior que solo un administrador puede sustituir.'
        return $true
    }
    if ([bool]$Parameters['NoInstall']) { return $false }
    try {
        . (Join-Path $PSScriptRoot 'Prerequisites.ps1')
        $full=[bool]$Parameters['Full'] -or -not [bool]$Parameters['MsiOnly']
        $state=Get-WinSlimPrerequisites $full ([bool]$Parameters['Legacy']) ([bool]$Parameters['SkipTests'])
        if (@($state.Missing).Count -gt 0) { Write-Host 'Faltan requisitos que hay que instalar.'; return $true }
        return $false
    } catch {
        # If detection itself fails, keep the previous behavior and elevate.
        return $true
    }
}

function Wait-WinSlimBuildConsole {
    Write-Host ''
    if ([Console]::IsInputRedirected) {
        $null=Read-Host 'Pulsa Entrar para cerrar esta ventana'
    } else {
        Write-Host 'Pulsa una tecla para cerrar esta ventana...'
        $null=[Console]::ReadKey($true)
    }
}

function Invoke-WinSlimBuildScript([string]$Path, [hashtable]$Parameters) {
    & $Path @Parameters | Out-Host
    return $LASTEXITCODE
}

function Invoke-WinSlimBuildLauncher([hashtable]$Parameters, [bool]$ElevatedChild, [string]$BuildScript) {
    $keepOpen=$Parameters.Count -eq 0
    if ($Parameters.ContainsKey('OutputDirectory') -and $Parameters.OutputDirectory) {
        # UAC can change the current directory; resolve a relative user path now.
        $Parameters.OutputDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Parameters.OutputDirectory)
    }
    $administrator=Test-WinSlimAdministrator
    $readOnly=$Parameters.ContainsKey('CheckOnly') -and [bool]$Parameters.CheckOnly
    if (-not $administrator -and -not $readOnly -and (Test-WinSlimElevationRequired $Parameters)) {
        try {
            if ($ElevatedChild) { throw 'La nueva consola no tiene permisos de administrador. No se volvera a solicitar elevacion.' }
            # Serialized data preserves switches, spaces, quotes and apostrophes.
            # No user-supplied argument or file path is interpolated as code.
            $payload=@{Launcher=(Join-Path $PSScriptRoot 'Launch-Build.ps1'); Parameters=$Parameters}
            $json=ConvertTo-Json -InputObject $payload -Depth 4 -Compress
            $data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
            $command=@'
$ProgressPreference='SilentlyContinue'
$payload=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__DATA__')))
$forward=@{}
foreach ($entry in $payload.Parameters.PSObject.Properties) { $forward[$entry.Name]=$entry.Value }
$forward['WinSlimElevated']=$true
& $payload.Launcher @forward
exit $LASTEXITCODE
'@
            $command=$command.Replace('__DATA__',$data)
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Write-Host 'Solicitando permisos de administrador para este build...'
            # CMD owns the visible console. PowerShell only runs the internal
            # orchestration in that console, without opening a PowerShell window.
            $cmd=Join-Path $env:SystemRoot 'System32\cmd.exe'
            $arguments='/d /s /c ""{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand {1}"' -f $powershell,$encoded
            if ($arguments.Length -gt 8000) { throw 'Los argumentos superan el limite de CMD. Usa rutas y opciones mas cortas.' }
            $process=Start-Process -FilePath $cmd -ArgumentList $arguments -Verb RunAs -WindowStyle Normal -Wait -PassThru
            return $process.ExitCode
        } catch {
            Write-Host ('No se pudo abrir la consola como administrador. Acepta la solicitud UAC y vuelve a ejecutar build.cmd. '+$_.Exception.Message) -ForegroundColor Red
            if ($keepOpen) { Wait-WinSlimBuildConsole }
            return 1
        }
    }
    $result=1
    try {
        if ($administrator) { Write-Host 'Open-Shell build - CMD - Administrador' }
        $result=Invoke-WinSlimBuildScript $BuildScript $Parameters
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    } finally {
        if ($keepOpen) { Wait-WinSlimBuildConsole }
    }
    return $result
}

# Dot-sourcing exposes only the functions for tests; it never launches a build.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    Set-StrictMode -Version Latest
    $forward=@{}
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Key -eq 'WinSlimElevated') { continue }
        $forward[$entry.Key]=if ($entry.Value -is [Management.Automation.SwitchParameter]) { [bool]$entry.Value } else { $entry.Value }
    }
    $result=Invoke-WinSlimBuildLauncher -Parameters $forward -ElevatedChild ([bool]$WinSlimElevated) -BuildScript (Join-Path $PSScriptRoot 'Build.ps1')
    exit $result
}
