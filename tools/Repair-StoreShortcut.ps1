# Preserve the AppsFolder PIDL; only remove a broken custom icon override.
param([switch]$Apply)
$ErrorActionPreference='Stop'
$source='C:\WSCore\Components\Hooks\Shortcuts\Tienda de aplicaciones.lnk'
$expectedTarget='Microsoft.WindowsStore_8wekyb3d8bbwe!App'
function Get-ShortcutPidl([string]$Path) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 78 -or [BitConverter]::ToUInt32($bytes,0) -ne 76 -or -not ([BitConverter]::ToUInt32($bytes,20) -band 1)) { throw 'Shortcut has no target PIDL' }
    $length=[BitConverter]::ToUInt16($bytes,76)
    if ($length -lt 2 -or 78+$length -gt $bytes.Length) { throw 'Invalid target PIDL length' }
    [Convert]::ToBase64String($bytes,78,$length)
}
$objects=[Collections.Generic.List[object]]::new()
try {
    $wsh=New-Object -ComObject WScript.Shell; $objects.Add($wsh)
    $original=$wsh.CreateShortcut($source); $objects.Add($original)
    $iconLocation=[string]$original.IconLocation
    $iconPath=($iconLocation -replace ',\s*-?\d+$','').Trim('"')
    $iconPath=[Environment]::ExpandEnvironmentVariables($iconPath)
    if (-not $iconPath -or (Test-Path -LiteralPath $iconPath)) {
        Write-Output 'No broken custom icon override; shortcut was not changed.'
        return
    }
    $before=Get-ShortcutPidl $source
    $temp=Join-Path $env:TEMP ('OpenShellStoreShortcut-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $candidate=Join-Path $temp 'Tienda de aplicaciones.lnk'
    Copy-Item -LiteralPath $source -Destination $candidate
    $changed=$wsh.CreateShortcut($candidate); $objects.Add($changed)
    $changed.IconLocation=',0'
    $changed.Save()
    if ((Get-ShortcutPidl $candidate) -ne $before) { throw 'Refusing repair: target PIDL changed' }
    $shell=New-Object -ComObject Shell.Application; $objects.Add($shell)
    $folder=$shell.NameSpace($temp); $objects.Add($folder)
    $item=$folder.ParseName([IO.Path]::GetFileName($candidate)); $objects.Add($item)
    $target=[string]$item.ExtendedProperty('System.Link.TargetParsingPath')
    if ($target -ne $expectedTarget) { throw "Refusing repair: unexpected application target $target" }
    Write-Output "Original missing icon: $iconPath"
    Write-Output "Verified candidate: $candidate"
    Write-Output "Target preserved: $target"
    if ($Apply) {
        $backupDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\WinSlim Profile\Backups'))
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        $backup=Join-Path $backupDirectory ('Tienda de aplicaciones-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.lnk.bak')
        Copy-Item -LiteralPath $source -Destination $backup
        try {
            Copy-Item -LiteralPath $candidate -Destination $source -Force
            if ((Get-ShortcutPidl $source) -ne $before) { throw 'Target verification failed after repair' }
        } catch {
            Copy-Item -LiteralPath $backup -Destination $source -Force
            throw
        }
        Write-Output "Shortcut repaired. Backup: $backup"
    }
} finally {
    for ($index=$objects.Count-1;$index -ge 0;$index--) {
        if ($objects[$index] -and [Runtime.InteropServices.Marshal]::IsComObject($objects[$index])) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($objects[$index])
        }
    }
}
