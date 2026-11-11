# Isolated orchestration tests. No downloads, installers or compiler executions.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Join-Path $PSScriptRoot 'Prerequisites.ps1'
function Assert-That([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$missing=[pscustomobject]@{Missing=@(@{Id='atl';Label='ATL'})}
$ready=[pscustomobject]@{Missing=@()}
foreach ($mode in @('ready','install','check','disabled','incomplete')) {
    & {
        param($mode,$missing,$ready,$module)
        . $module
        $script:detections=0; $script:installations=0
        function Get-WinSlimPrerequisites([bool]$Full,[bool]$Legacy,[bool]$SkipTests) {
            $script:detections++
            if ($mode -eq 'ready' -or ($mode -eq 'install' -and $script:detections -gt 1)) { return $ready }
            return $missing
        }
        function Install-WinSlimPrerequisites($State,[bool]$Full,[bool]$Legacy,[bool]$SkipTests) {
            $script:installations++
            Assert-That ($State.Missing[0].Id -eq 'atl') 'The detected installation plan was lost'
        }
        $failure=$null
        try { $null=Ensure-WinSlimPrerequisites $true $false $false ($mode -eq 'check') ($mode -eq 'disabled') }
        catch { $failure=$_ }
        $shouldInstall=$mode -in @('install','incomplete')
        Assert-That ($script:installations -eq [int]$shouldInstall) "Unexpected installation in mode $mode"
        Assert-That (($null -ne $failure) -eq ($mode -in @('check','disabled','incomplete'))) "Wrong failure/continuation in mode $mode"
        Assert-That ($script:detections -eq $(if ($shouldInstall) { 2 } else { 1 })) "Missing post-install verification in mode $mode"
        Write-Output "Prerequisites scenario passed: $mode"
    } $mode $missing $ready $module
}
foreach ($code in @(0,3010,1641,1603)) {
    & {
        param($code,$module)
        . $module
        function Start-Process {
            param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$WindowStyle,$Verb)
            Assert-That ($Wait -and $PassThru -and $WindowStyle -eq 'Hidden') 'Installer must be awaited and hidden'
            Assert-That ($ArgumentList -eq 'modify --installPath "C:\Tools With Spaces"') 'Installer arguments were not preserved'
            [pscustomobject]@{ExitCode=$code}
        }
        $failure=$null
        try { Invoke-WinSlimInstaller 'C:\fake-installer.exe' @('modify','--installPath','C:\Tools With Spaces') -Elevated }
        catch { $failure=$_ }
        Assert-That (($null -ne $failure) -eq ($code -ne 0)) "Wrong installer exit handling: $code"
        if ($code -in @(3010,1641)) { Assert-That ($failure.Exception.Message -like '*reiniciar*') 'Restart must stop the build with clear instructions' }
        Write-Output "Installer exit scenario passed: $code"
    } $code $module
}
& {
    . $module
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$WindowStyle,$Verb)
        Assert-That (-not $Wait -and $PassThru) 'Bounded installer wait must own the process wait'
        Assert-That ($ArgumentList -eq '/i "C:\Tools With Spaces\7zip.msi" /qn /norestart') 'MSI switches must remain unquoted'
        $process=[pscustomobject]@{Handle=[IntPtr]::Zero; Id=123; ExitCode=0}
        $process | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $true }
        return $process
    }
    Invoke-WinSlimInstaller 'C:\fake-msiexec.exe' @('/i','C:\Tools With Spaces\7zip.msi','/qn','/norestart') -TimeoutSeconds 10
    $blocked=[pscustomobject]@{Handle=[IntPtr]::Zero; Id=456; ExitCode=0}
    $blocked | Add-Member ScriptMethod WaitForExit { param($milliseconds) return $false }
    $failure=$null
    try { $null=Wait-WinSlimInstallerProcess $blocked 0 'C:\fake.log' } catch { $failure=$_ }
    Assert-That ($null -ne $failure -and $failure.Exception -is [TimeoutException]) 'Blocked installer did not time out'
    Assert-That ($failure.Exception.Message -like '*456*fake.log*') 'Timeout must identify the process and log'
    Write-Output 'MSI switch quoting and bounded wait scenarios passed'
}
& {
    . $module
    function Start-Process {
        param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$WindowStyle,$Verb,$WorkingDirectory)
        Assert-That ($ArgumentList -eq 'advpack.dll,LaunchINFSectionEx "C:\Tools With Spaces\htmlhelp.inf",,,12,N') 'HTML Help INF argument quoting changed'
        Assert-That ($WorkingDirectory -eq 'C:\Tools With Spaces') 'HTML Help source directory was lost'
        [pscustomobject]@{ExitCode=0}
    }
    Invoke-WinSlimInstaller -FilePath 'C:\fake-rundll32.exe' -ArgumentLine 'advpack.dll,LaunchINFSectionEx "C:\Tools With Spaces\htmlhelp.inf",,,12,N' -WorkingDirectory 'C:\Tools With Spaces' -Elevated
    Write-Output 'HTML Help argument scenario passed'
}
& {
    . $module
    Assert-That (-not (Test-WinSlimCommand $env:ComSpec @('/d','/c','echo cargo 1.2.3') -MinimumVersion ([version]'1.83.0'))) 'Obsolete Rust version was accepted'
    Assert-That (Test-WinSlimCommand $env:ComSpec @('/d','/c','echo cargo 1.83.0') -MinimumVersion ([version]'1.83.0')) 'Supported Rust version was rejected'
    Write-Output 'Tool version checks passed'
    $inf="[DefaultInstall]`r`nRunPostSetupCommands=HHUpdate`r`nRegisterOCXs=RegisterItccDLL`r`n[DefaultInstall.NT]`r`nRunPostSetupCommands=HHUpdate`t; comment`r`n[DefaultInstall.NT5]`r`nRunPostSetupCommands=HHUpdate`t; comment`r`n"
    $fixed=Disable-WinSlimLegacyHelpUpdate $inf
    Assert-That ($fixed -notmatch '(?im)^RunPostSetupCommands=') 'Commented INF entries left the obsolete updater active'
    Assert-That ($fixed -match 'RegisterOCXs=RegisterItccDLL') 'HTML Help COM registration was removed'
    Write-Output 'Legacy Help updater scenario passed'
}
Write-Output 'Prerequisite orchestration checks passed. No software was installed.'
