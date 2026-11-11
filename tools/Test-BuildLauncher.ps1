# Tests use mocked process/elevation/build functions. Never opens UAC or compiles.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$launcher=Join-Path $PSScriptRoot 'Launch-Build.ps1'
function Assert-Launcher([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
foreach ($scenario in @('elevate','already-admin','check-only','cancel','loop-guard','no-elevation')) {
    & {
        param($scenario,$launcher)
        . $launcher
        $script:started=0; $script:built=0; $script:paused=0
        $parameters=@{}
        if ($scenario -eq 'elevate') { $parameters=@{Version="4.4.1000-test'quote";Language='Spanish';MsiOnly=$true;SkipTests=$false;OutputDirectory="C:\Fake project's Release"} }
        if ($scenario -eq 'check-only') { $parameters=@{CheckOnly=$true} }
        function Test-WinSlimAdministrator { $scenario -eq 'already-admin' }
        # 'no-elevation': every prerequisite is present, so no installer needs UAC.
        function Test-WinSlimElevationRequired([hashtable]$Parameters) { $scenario -ne 'no-elevation' }
        function Wait-WinSlimBuildConsole { $script:paused++ }
        function Invoke-WinSlimBuildScript([string]$Path,[hashtable]$Parameters) {
            $script:built++
            Assert-Launcher ($Path -eq 'C:\Fake Project\Build.ps1') 'Build script path changed'
            if ($scenario -eq 'check-only') { Assert-Launcher ([bool]$Parameters.CheckOnly) 'CheckOnly was lost' }
            return 23
        }
        function Start-Process {
            param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru)
            $script:started++
            Assert-Launcher ($Verb -eq 'RunAs' -and $WindowStyle -eq 'Normal') 'Elevation must use UAC and a visible console'
            Assert-Launcher ([IO.Path]::GetFileName($FilePath) -ieq 'cmd.exe') 'The elevated console must run CMD'
            Assert-Launcher ($Wait -and $PassThru) 'Parent must wait for the elevated result'
            Assert-Launcher ($ArgumentList.Length -le 8000) 'CMD command line is too long'
            if ($scenario -eq 'cancel') { throw 'UAC canceled' }
            $encoded=[regex]::Match($ArgumentList,'-EncodedCommand ([A-Za-z0-9+/=]+)"$').Groups[1].Value
            $command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            $data=[regex]::Match($command,"FromBase64String\('([^']+)'\)").Groups[1].Value
            $payload=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data)))
            Assert-Launcher ($payload.Parameters.Version -eq $parameters.Version) 'Quotes in argument data changed'
            Assert-Launcher ($payload.Parameters.Language -eq 'Spanish') 'Language argument changed'
            Assert-Launcher ($payload.Parameters.OutputDirectory -eq $parameters.OutputDirectory) 'Release output directory changed during elevation'
            Assert-Launcher ([bool]$payload.Parameters.MsiOnly -and -not [bool]$payload.Parameters.SkipTests) 'Switch values changed'
            Assert-Launcher ($payload.Launcher -eq $launcher) 'Elevation relaunches the wrong file'
            return [pscustomobject]@{ExitCode=19}
        }
        $result=Invoke-WinSlimBuildLauncher $parameters ($scenario -eq 'loop-guard') 'C:\Fake Project\Build.ps1'
        $expectedStarts=if ($scenario -in @('elevate','cancel')) { 1 } else { 0 }
        $expectedBuilds=if ($scenario -in @('already-admin','check-only','no-elevation')) { 1 } else { 0 }
        $expectedPauses=if ($scenario -in @('already-admin','cancel','loop-guard','no-elevation')) { 1 } else { 0 }
        $expectedResult=if ($scenario -eq 'elevate') { 19 } elseif ($expectedBuilds) { 23 } else { 1 }
        Assert-Launcher ($script:started -eq $expectedStarts) "Wrong elevation count: $scenario"
        Assert-Launcher ($script:built -eq $expectedBuilds) "Unexpected build dispatch: $scenario"
        Assert-Launcher ($script:paused -eq $expectedPauses) "Wrong console pause count: $scenario"
        Assert-Launcher ($result -eq $expectedResult) "Exit code lost: $scenario"
        Write-Output "Build launcher scenario passed: $scenario"
    } $scenario $launcher
}
& {
    . $launcher
    # -NoInstall never installs anything, so it must not even run detection or ask for UAC...
    function Test-WinSlimProtectedOutput { $false }
    Assert-Launcher (-not (Test-WinSlimElevationRequired @{NoInstall=$true})) 'NoInstall must not request elevation'
    # ...but MSIs left by an older elevated build can only be replaced by an elevated build.
    function Test-WinSlimProtectedOutput { $true }
    $required=Test-WinSlimElevationRequired @{NoInstall=$true} 6>$null
    Assert-Launcher $required 'Protected build outputs must request elevation'
}
$tokens=$null; $errors=$null
$buildAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Build.ps1'),[ref]$tokens,[ref]$errors)
$launcherAst=[Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
$publicNames=@($launcherAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($parameter in $buildAst.ParamBlock.Parameters) {
    Assert-Launcher ($parameter.Name.VariablePath.UserPath -in $publicNames) 'Launcher does not support a build parameter'
}
Write-Output 'Build launcher checks passed. No UAC, installers or compilers were executed.'
