# Read-only inspection of the user's Store shortcut and registered app package.
$ErrorActionPreference='Stop'
$directory='C:\WSCore\Components\Hooks\Shortcuts'
$objects=[Collections.Generic.List[object]]::new()
try {
    $wsh=New-Object -ComObject WScript.Shell; $objects.Add($wsh)
    $shell=New-Object -ComObject Shell.Application; $objects.Add($shell)
    $folder=$shell.NameSpace($directory); if ($folder) { $objects.Add($folder) }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter 'Tienda*.lnk') {
        $link=$wsh.CreateShortcut($file.FullName); $objects.Add($link)
        [pscustomobject]@{Shortcut=$file.FullName;Target=$link.TargetPath;Arguments=$link.Arguments;Icon=$link.IconLocation;WorkingDirectory=$link.WorkingDirectory} | Format-List
        if ($folder) {
            $item=$folder.ParseName($file.Name); $objects.Add($item)
            [pscustomobject]@{AppId=$item.ExtendedProperty('System.AppUserModel.ID');TargetParsingPath=$item.ExtendedProperty('System.Link.TargetParsingPath')} | Format-List
            try {
                $shellLink=$item.GetLink; $objects.Add($shellLink)
                $target=$shellLink.Target; if ($target) { $objects.Add($target); Write-Output ('Shell target: '+$target.Path) }
            } catch { Write-Output $_.Exception.Message }
        }
    }
    Get-AppxPackage -Name Microsoft.WindowsStore | Select-Object Name,Version,PackageFamilyName,InstallLocation | Format-List
} finally {
    for ($index=$objects.Count-1;$index -ge 0;$index--) {
        if ($objects[$index] -and [Runtime.InteropServices.Marshal]::IsComObject($objects[$index])) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($objects[$index])
        }
    }
}
